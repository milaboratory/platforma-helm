#!/usr/bin/env bash
# =============================================================================
# Platforma on GCP — Infrastructure Manager installer
# =============================================================================
# Submits / updates a Google Cloud Infrastructure Manager deployment that
# provisions the full Platforma stack on GKE: VPC, cluster + node pools,
# Filestore, GCS bucket, Workload Identity, Kueue/AppWrapper, the Platforma
# Helm release, plus an HTTPS ingress (Certificate Manager + Cloud DNS A
# record + GKE Gateway).
#
# Designed to run from Google Cloud Shell as the active step of tutorial.md,
# but works standalone — set the env vars listed below and execute.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# IM bundle version. Bump on each release. Released bundles live at
# gs://platforma-infrastructure-manager/platforma-gcp-<version>.tar.gz
IM_BUNDLE_VERSION="${IM_BUNDLE_VERSION:-dev-3df088e}"
IM_BUNDLE_URL="gs://platforma-infrastructure-manager/platforma-gcp-${IM_BUNDLE_VERSION}.tar.gz"

# Service account that Infrastructure Manager runs Terraform under. Created
# in the user's project on first run; granted Owner so it can provision GKE,
# Filestore, IAM, etc. (Power users can swap to a fine-grained role set —
# see infrastructure/gcp/permissions.md.)
IM_DEPLOYER_SA_NAME="platforma-im-deployer"

# Location for the IM deployment object itself (separate from var.region —
# IM is regional and accepts a different region from the workload).
IM_LOCATION_DEFAULT="europe-west1"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { red "Required command '$1' not found in PATH."; exit 1; }
}

# prompt_var <var-name> <prompt> [default]
# If the var is already set in the environment, keeps it. Otherwise prompts
# (with optional default). Stops if user enters empty for a no-default field.
prompt_var() {
  local name="$1"; local prompt="$2"; local default="${3:-}"
  local current="${!name:-}"
  if [[ -n "${current}" ]]; then
    info "${name} = ${current}  (from env)"
    return
  fi
  local input
  if [[ -n "${default}" ]]; then
    read -r -p "  ${prompt} [${default}]: " input
    input="${input:-${default}}"
  else
    read -r -p "  ${prompt}: " input
  fi
  if [[ -z "${input}" ]]; then
    red "${name} is required."; exit 1
  fi
  printf -v "${name}" '%s' "${input}"
}

prompt_secret_var() {
  local name="$1"; local prompt="$2"
  local current="${!name:-}"
  if [[ -n "${current}" ]]; then
    info "${name} = ********  (from env)"
    return
  fi
  local input
  read -r -s -p "  ${prompt}: " input; echo
  if [[ -z "${input}" ]]; then
    red "${name} is required."; exit 1
  fi
  printf -v "${name}" '%s' "${input}"
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

preflight() {
  bold "Pre-flight checks"

  require_command gcloud

  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    red "No active GCP project. Run: gcloud config set project YOUR_PROJECT"
    exit 1
  fi
  info "Project:        ${PROJECT_ID}"

  # Billing must be enabled, else IM will fail late with a confusing error.
  if ! gcloud beta billing projects describe "${PROJECT_ID}" --format="value(billingEnabled)" 2>/dev/null | grep -q True; then
    red "Billing is NOT enabled on ${PROJECT_ID}."
    red "Enable: https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}"
    exit 1
  fi
  info "Billing:        enabled"

  # Application Default Credentials must have a quota project bound for the
  # cloudquotas.googleapis.com API our TF module uses.
  gcloud auth application-default set-quota-project "${PROJECT_ID}" 2>/dev/null || true
  info "ADC quota project bound to ${PROJECT_ID}"

  # Enable infra-manager + cloud-quotas APIs upfront — TF will enable the rest
  # but these two are needed for the IM call itself.
  info "Enabling required bootstrap APIs (config, cloudquotas)…"
  gcloud services enable \
    config.googleapis.com \
    cloudquotas.googleapis.com \
    --project="${PROJECT_ID}" --quiet

  echo
}

# -----------------------------------------------------------------------------
# Inputs
# -----------------------------------------------------------------------------

collect_inputs() {
  bold "Deployment inputs"
  prompt_var DEPLOYMENT_NAME "Deployment name (lowercase letters/digits/dashes)"   "platforma"
  prompt_var IM_LOCATION     "IM deployment region"                                "${IM_LOCATION_DEFAULT}"
  prompt_var REGION          "GCP region for the cluster"                          "europe-west1"
  prompt_var ZONE_SUFFIX     "Zone suffix (a/b/c/d) for zonal resources"           "b"
  prompt_var DEPLOYMENT_SIZE "Deployment size (small|medium|large|xlarge)"         "small"
  echo

  pick_dns_zone_and_domain

  prompt_var CONTACT_EMAIL   "Email for quota/notification mail"                   "$(gcloud config get-value account 2>/dev/null || echo '')"
  prompt_and_validate_license
  echo

  collect_auth_inputs
  collect_data_libraries
}

# -----------------------------------------------------------------------------
# License key — visible input (so the user can spot typos when pasting) and
# on-the-fly validation against MiLaboratories' licensing API. Same endpoint
# the Platforma server itself hits at runtime, so a key that passes here is
# effectively certain to work in the cluster.
# -----------------------------------------------------------------------------

LICENSING_API_URL="${LICENSING_API_URL:-https://licensing-api.milaboratories.com/refresh-token}"

prompt_and_validate_license() {
  if [[ -n "${LICENSE_KEY:-}" ]]; then
    info "LICENSE_KEY from env, validating…"
    if validate_license "${LICENSE_KEY}"; then
      green "  ✓ License OK"
      return 0
    fi
    red "License from env failed validation."
    LICENSE_KEY=""
  fi

  while :; do
    local input
    read -r -p "  Platforma license key (E-…) — input visible so you can spot typos: " input
    input="${input// /}"  # strip stray whitespace from paste
    if [[ -z "${input}" ]]; then
      red "  License key is required."
      continue
    fi
    if validate_license "${input}"; then
      LICENSE_KEY="${input}"
      green "  ✓ License OK"
      return 0
    fi
    red "  License validation failed — try again or Ctrl-C to abort."
  done
}

# 0 = valid, 1 = invalid (with error printed)
validate_license() {
  local key="$1"
  local body; body="$(mktemp)"
  local code
  code="$(curl -s -o "${body}" -w '%{http_code}' --max-time 15 \
    "${LICENSING_API_URL}?code=$(printf '%s' "${key}" | jq -sRr @uri)")"
  if [[ "${code}" == "200" ]]; then
    rm -f "${body}"
    return 0
  fi
  red "    HTTP ${code} from ${LICENSING_API_URL}"
  if command -v jq >/dev/null 2>&1; then
    local msg; msg="$(jq -r '.message // .error // .errors // empty' "${body}" 2>/dev/null | head -3)"
    [[ -n "${msg}" ]] && printf '    %s\n' "${msg}" | sed 's/^/    /'
  fi
  rm -f "${body}"
  return 1
}

# -----------------------------------------------------------------------------
# DNS zone + domain — pick from existing Cloud DNS managed zones in the project
# and derive the FQDN from a subdomain prefix. Avoids users typing a domain
# that doesn't match any zone they own.
# -----------------------------------------------------------------------------

pick_dns_zone_and_domain() {
  bold "Domain"

  if [[ -n "${DOMAIN_NAME:-}" && -n "${DNS_ZONE_NAME:-}" ]]; then
    info "DOMAIN_NAME=${DOMAIN_NAME}, DNS_ZONE_NAME=${DNS_ZONE_NAME} from env."
    echo
    return 0
  fi

  local zones_json
  zones_json="$(gcloud dns managed-zones list --project="${PROJECT_ID}" --format=json 2>/dev/null || echo '[]')"
  local count
  count="$(echo "${zones_json}" | jq 'length')"

  if (( count == 0 )); then
    red "No Cloud DNS managed zones in project ${PROJECT_ID}."
    red "Create one first, then re-run this script:"
    red "  gcloud dns managed-zones create my-zone \\"
    red "    --dns-name=mycompany.com. --visibility=public --project=${PROJECT_ID}"
    red "Then delegate NS records from your registrar — see infrastructure/gcp/domain-guide.md."
    exit 1
  fi

  echo "  Available Cloud DNS managed zones in ${PROJECT_ID}:"
  local idx=1
  declare -a ZONE_NAMES=() ZONE_DNS=()
  while IFS=$'\t' read -r name dns_name; do
    printf '    %d. %-32s  (%s)\n' "${idx}" "${name}" "${dns_name}"
    ZONE_NAMES+=("${name}")
    ZONE_DNS+=("${dns_name%.}")  # strip trailing dot
    ((idx++))
  done < <(echo "${zones_json}" | jq -r '.[] | "\(.name)\t\(.dnsName)"')
  echo

  local pick
  if (( count == 1 )); then
    pick=1
    info "Only one zone — auto-selected: ${ZONE_NAMES[0]} (${ZONE_DNS[0]})"
  else
    read -r -p "  Select zone [1-${count}]: " pick
    if [[ ! "${pick}" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > count )); then
      red "Invalid selection '${pick}'."; exit 1
    fi
  fi

  DNS_ZONE_NAME="${ZONE_NAMES[$((pick-1))]}"
  local zone_dns="${ZONE_DNS[$((pick-1))]}"

  local prefix
  read -r -p "  Subdomain for Platforma (full domain will be <prefix>.${zone_dns}) [${DEPLOYMENT_NAME}]: " prefix
  prefix="${prefix:-${DEPLOYMENT_NAME}}"
  if [[ ! "${prefix}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
    red "Invalid subdomain '${prefix}' — must be alphanumeric + hyphens, not starting/ending with hyphen."; exit 1
  fi

  DOMAIN_NAME="${prefix}.${zone_dns}"
  green "  ✓ DOMAIN_NAME   = ${DOMAIN_NAME}"
  green "  ✓ DNS_ZONE_NAME = ${DNS_ZONE_NAME}"
  echo
}

# -----------------------------------------------------------------------------
# Auth: htpasswd (auto-gen / user-supplied content) or LDAP
# -----------------------------------------------------------------------------

collect_auth_inputs() {
  bold "Authentication"
  cat <<EOF
  How will users sign in to Platforma?

    htpasswd  — file-based local auth. Pick this for testing or single-team
                use. By default the installer auto-generates a random admin
                password and stores it in Secret Manager (TESTING ONLY — the
                password ends up in Terraform state). For production set
                HTPASSWD_CONTENT env var to pre-bcrypted content.
    ldap      — corporate directory integration (Active Directory, OpenLDAP,
                etc.). Use this in production when access should be governed
                by your central directory.

EOF
  prompt_var AUTH_METHOD "Auth method (htpasswd|ldap)" "htpasswd"

  case "${AUTH_METHOD}" in
    htpasswd)
      if [[ -n "${HTPASSWD_CONTENT:-}" ]]; then
        info "htpasswd content provided via env (${#HTPASSWD_CONTENT} bytes)."
      else
        warn "Auto-generating random htpasswd password (testing only)."
        warn "For production: pre-generate with 'htpasswd -nB <user>' and export HTPASSWD_CONTENT before re-running."
      fi
      ;;
    ldap)
      prompt_var       LDAP_SERVER         "LDAP server URL (e.g. ldaps://ldap.example.com:636)"
      prompt_var       LDAP_START_TLS      "Enable StartTLS? (true|false)" "false"
      info "Pick ONE bind mode below — leave the other empty."
      prompt_var       LDAP_BIND_DN        "Direct-bind DN template (e.g. cn=%u,ou=users,dc=example,dc=com) — empty to use search bind" ""
      if [[ -z "${LDAP_BIND_DN}" ]]; then
        prompt_var     LDAP_SEARCH_RULES   "Search bind rules — SEMICOLON-separated 'filter|baseDN' entries (e.g. (uid=%u)|ou=users,dc=example,dc=com;(cn=%u)|ou=admins,dc=example,dc=com)"
        prompt_var     LDAP_SEARCH_USER    "Search service account DN"
        prompt_secret_var LDAP_SEARCH_PASSWORD "Search service account password"
      fi
      ;;
    *)
      red "Invalid auth_method '${AUTH_METHOD}' — must be htpasswd or ldap."; exit 1
      ;;
  esac
  echo
}

# -----------------------------------------------------------------------------
# Data libraries: external read-only buckets (where users keep their fastq /
# input data). Up to 3 prompted interactively; power users can pre-fill the
# DATA_LIBRARIES_YAML env var with full YAML for arbitrary entries and skip
# the prompts.
# -----------------------------------------------------------------------------

collect_data_libraries() {
  bold "Data libraries"
  cat <<EOF
  External buckets containing your input data (e.g. fastq files). Without
  data libraries, the cluster has no real input data — only the included
  demo dataset (if enabled).

EOF
  prompt_var ENABLE_DEMO "Enable MiLaboratories demo data library? (true|false)" "true"

  if [[ -n "${DATA_LIBRARIES_YAML:-}" ]]; then
    info "Custom data libraries provided via DATA_LIBRARIES_YAML env var (${#DATA_LIBRARIES_YAML} bytes)."
    return
  fi

  prompt_var DATA_LIBRARY_COUNT "Number of additional data libraries (0-3)" "0"

  DATA_LIBRARIES_BUILT=()
  local i
  for ((i=1; i<=DATA_LIBRARY_COUNT; i++)); do
    bold "Library ${i}"
    local name_var="LIB_${i}_NAME"
    local type_var="LIB_${i}_TYPE"
    local bucket_var="LIB_${i}_BUCKET"
    local prefix_var="LIB_${i}_PREFIX"
    local region_var="LIB_${i}_REGION"
    local key_var="LIB_${i}_ACCESS_KEY"
    local secret_var="LIB_${i}_SECRET_KEY"

    prompt_var "${name_var}"   "Name (lowercase, alphanumeric+dash; shows in Desktop App)"
    prompt_var "${type_var}"   "Type (gcs|s3)" "gcs"
    prompt_var "${bucket_var}" "Bucket name"
    prompt_var "${prefix_var}" "Path prefix within bucket (optional)" ""

    if [[ "${!type_var}" == "s3" ]]; then
      prompt_var "${region_var}" "AWS region (required for AWS S3)" "us-east-1"
      prompt_var "${key_var}"    "Access key (leave empty for IAM-role / Workload Identity access)" ""
      if [[ -n "${!key_var}" ]]; then
        prompt_secret_var "${secret_var}" "Secret key"
      fi
    else
      info "Same-project GCS uses Workload Identity. For cross-project access, grant 'platforma-server@${PROJECT_ID}.iam.gserviceaccount.com' the roles/storage.objectViewer role on the bucket BEFORE running this installer."
      # No key prompts for GCS — Workload Identity handles auth.
    fi

    DATA_LIBRARIES_BUILT+=("${i}")
  done
  echo
}

# -----------------------------------------------------------------------------
# Detect existing user-managed quota preferences in the project — Cloud Quotas
# API rejects duplicate creates and exposes no DELETE method, so any quota the
# user already has a preference for must be passed via skip_quota_requests
# instead of letting our TF module create one.
#
# Also warns when the existing preferred value is below what the chosen
# deployment_size needs (the deployment will succeed but may run out of
# quota during scale-up).
#
# Lookup table mirrors presets.tf — keep in sync on each preset change.
# -----------------------------------------------------------------------------

declare -A PRESET_CPUS_GLOBAL=(    [small]=512  [medium]=1024 [large]=2048 [xlarge]=4096  )
declare -A PRESET_N2D_CPUS=(       [small]=512  [medium]=1024 [large]=2048 [xlarge]=4096  )
declare -A PRESET_PD_SSD_GB=(      [small]=2048 [medium]=4096 [large]=8192 [xlarge]=16384 )
declare -A PRESET_INSTANCES=(      [small]=32   [medium]=48   [large]=64   [xlarge]=128   )
declare -A PRESET_FILESTORE_GB=(   [small]=1024 [medium]=2048 [large]=4096 [xlarge]=8192  )

# Map GCP quota ID → our preset_key + required-value lookup.
declare -A QUOTA_TO_PRESET_KEY=(
  ["CPUS-ALL-REGIONS-per-project"]="cpus_global"
  ["N2D-CPUS-per-project-region"]="n2d_cpus_region"
  ["SSD-TOTAL-GB-per-project-region"]="pd_ssd_region"
  ["INSTANCES-per-project-region"]="instances_region"
  ["EnterpriseStorageGibPerRegion"]="filestore_zonal_region"
)

# What value each preset key needs for the chosen DEPLOYMENT_SIZE.
required_for_preset_key() {
  local key="$1"
  case "${key}" in
    cpus_global)             echo "${PRESET_CPUS_GLOBAL[$DEPLOYMENT_SIZE]}"   ;;
    n2d_cpus_region)         echo "${PRESET_N2D_CPUS[$DEPLOYMENT_SIZE]}"      ;;
    pd_ssd_region)           echo "${PRESET_PD_SSD_GB[$DEPLOYMENT_SIZE]}"     ;;
    instances_region)        echo "${PRESET_INSTANCES[$DEPLOYMENT_SIZE]}"     ;;
    filestore_zonal_region)  echo "${PRESET_FILESTORE_GB[$DEPLOYMENT_SIZE]}"  ;;
  esac
}

detect_existing_quota_prefs() {
  bold "Checking existing quota preferences"
  SKIP_QUOTA_REQUESTS_AUTO=()

  # The beta component is required and may not be installed in raw envs.
  if ! gcloud beta quotas preferences list --help >/dev/null 2>&1; then
    info "Installing gcloud beta component (one-time)…"
    gcloud components install beta --quiet >/dev/null
  fi

  local prefs_json
  prefs_json="$(gcloud beta quotas preferences list --project="${PROJECT_ID}" --format=json 2>/dev/null || echo '[]')"

  if [[ "${prefs_json}" == "[]" || -z "${prefs_json}" ]]; then
    info "No existing user-managed quota preferences."
    echo
    return 0
  fi

  local count
  count="$(echo "${prefs_json}" | jq 'length')"
  info "Found ${count} existing preference(s) — checking for collisions with our presets."

  local has_warning=0
  while IFS=$'\t' read -r quota_id region preferred; do
    local preset_key="${QUOTA_TO_PRESET_KEY[${quota_id}]:-}"
    [[ -z "${preset_key}" ]] && continue   # unrelated quota — ignore
    SKIP_QUOTA_REQUESTS_AUTO+=("${preset_key}")
    local required; required="$(required_for_preset_key "${preset_key}")"
    local label="${quota_id}${region:+ (region=${region})}"
    if (( preferred < required )); then
      warn "Existing quota ${label}: current=${preferred} < required=${required} for ${DEPLOYMENT_SIZE}"
      warn "  → deployment will succeed but may run out of quota during job scale-up."
      warn "  → bump at: https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
      has_warning=1
    else
      info "Existing quota ${label}: ${preferred} ≥ ${required} ✓ (will skip auto-request)"
    fi
  done < <(echo "${prefs_json}" | jq -r '.[] | "\(.quotaId)\t\(.dimensions.region // "")\t\(.quotaConfig.preferredValue // "0")"')

  if (( has_warning > 0 )); then
    echo
    read -r -p "  Existing quotas are below preset requirements. Continue anyway? [y/N] " confirm
    case "${confirm}" in
      y|Y|yes|YES) ;;
      *) red "Aborted."; exit 1 ;;
    esac
  fi
  echo
}

# -----------------------------------------------------------------------------
# Service account for Infrastructure Manager
# -----------------------------------------------------------------------------

ensure_im_service_account() {
  bold "Infrastructure Manager service account"
  local sa_email="${IM_DEPLOYER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

  if ! gcloud iam service-accounts describe "${sa_email}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    info "Creating ${sa_email}…"
    gcloud iam service-accounts create "${IM_DEPLOYER_SA_NAME}" \
      --display-name="Platforma Infrastructure Manager deployer" \
      --project="${PROJECT_ID}" --quiet
  else
    info "Already exists: ${sa_email}"
  fi

  # Grant Owner on the project — IM needs to create GKE, Filestore, IAM
  # bindings, DNS records, etc. For tighter scopes see permissions.md.
  info "Granting roles/owner to ${sa_email} on ${PROJECT_ID}…"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${sa_email}" \
    --role="roles/owner" \
    --condition=None --quiet >/dev/null

  IM_SA_EMAIL="${sa_email}"
  echo
}

# -----------------------------------------------------------------------------
# Submit / update IM deployment
# -----------------------------------------------------------------------------

# Builds a YAML file at $1 with all TF inputs. Uses YAML (not the simpler
# inline --input-values=key=value form) because data_libraries is a list of
# objects and ldap_search_rules is a list of strings — neither is expressible
# in the comma-separated inline format.
build_inputs_file() {
  local out="$1"
  : > "${out}"

  cat >> "${out}" <<EOF
project_id: "${PROJECT_ID}"
region: "${REGION}"
zone_suffix: "${ZONE_SUFFIX}"
cluster_name: "${DEPLOYMENT_NAME}-cluster"
deployment_size: "${DEPLOYMENT_SIZE}"
ingress_enabled: true
domain_name: "${DOMAIN_NAME}"
dns_zone_name: "${DNS_ZONE_NAME}"
contact_email: "${CONTACT_EMAIL}"
license_key: "${LICENSE_KEY}"
enable_demo_data_library: ${ENABLE_DEMO}
auth_method: "${AUTH_METHOD}"
EOF

  # Auto-detected quota preference collisions (and any user-supplied additions).
  local skip_list=("${SKIP_QUOTA_REQUESTS_AUTO[@]:-}")
  if [[ -n "${SKIP_QUOTA_REQUESTS:-}" ]]; then
    local IFS=','
    for k in ${SKIP_QUOTA_REQUESTS}; do skip_list+=("${k}"); done
  fi
  if (( ${#skip_list[@]} > 0 )); then
    # Dedupe + drop empty entries.
    local unique; unique="$(printf '%s\n' "${skip_list[@]}" | awk 'NF && !seen[$0]++')"
    if [[ -n "${unique}" ]]; then
      echo "skip_quota_requests:" >> "${out}"
      while IFS= read -r k; do
        printf '  - %s\n' "$(yaml_quote "${k}")" >> "${out}"
      done <<< "${unique}"
    fi
  fi

  # Auth — emit only the path that's relevant.
  if [[ "${AUTH_METHOD}" == "htpasswd" && -n "${HTPASSWD_CONTENT:-}" ]]; then
    # Use printf so newlines/specials inside HTPASSWD_CONTENT survive.
    printf 'htpasswd_content: %s\n' "$(yaml_quote "${HTPASSWD_CONTENT}")" >> "${out}"
  fi
  if [[ "${AUTH_METHOD}" == "ldap" ]]; then
    cat >> "${out}" <<EOF
ldap_server: "${LDAP_SERVER}"
ldap_start_tls: ${LDAP_START_TLS}
ldap_bind_dn: "${LDAP_BIND_DN}"
ldap_search_user: "${LDAP_SEARCH_USER:-}"
EOF
    if [[ -n "${LDAP_SEARCH_PASSWORD:-}" ]]; then
      printf 'ldap_search_password: %s\n' "$(yaml_quote "${LDAP_SEARCH_PASSWORD}")" >> "${out}"
    fi
    # Semicolon-separated rules → YAML list (commas appear inside DNs so they
    # can't be the separator).
    if [[ -n "${LDAP_SEARCH_RULES:-}" ]]; then
      echo "ldap_search_rules:" >> "${out}"
      local IFS=';'
      for rule in ${LDAP_SEARCH_RULES}; do
        printf '  - %s\n' "$(yaml_quote "${rule}")" >> "${out}"
      done
    fi
  fi

  # Data libraries — preserve a user-supplied YAML block verbatim, otherwise
  # synthesize from the per-library prompts.
  if [[ -n "${DATA_LIBRARIES_YAML:-}" ]]; then
    printf 'data_libraries:\n%s\n' "${DATA_LIBRARIES_YAML}" >> "${out}"
  elif (( ${#DATA_LIBRARIES_BUILT[@]} > 0 )); then
    echo "data_libraries:" >> "${out}"
    local i
    for i in "${DATA_LIBRARIES_BUILT[@]}"; do
      local name="LIB_${i}_NAME"
      local type="LIB_${i}_TYPE"
      local bucket="LIB_${i}_BUCKET"
      local prefix="LIB_${i}_PREFIX"
      local region="LIB_${i}_REGION"
      local key="LIB_${i}_ACCESS_KEY"
      local secret="LIB_${i}_SECRET_KEY"

      printf '  - name: %s\n'   "$(yaml_quote "${!name}")"   >> "${out}"
      printf '    type: %s\n'   "$(yaml_quote "${!type}")"   >> "${out}"
      printf '    bucket: %s\n' "$(yaml_quote "${!bucket}")" >> "${out}"
      [[ -n "${!prefix}"   ]] && printf '    prefix: %s\n'     "$(yaml_quote "${!prefix}")" >> "${out}" || true
      [[ -n "${!region:-}" ]] && printf '    region: %s\n'     "$(yaml_quote "${!region}")" >> "${out}" || true
      [[ -n "${!key:-}"    ]] && printf '    access_key: %s\n' "$(yaml_quote "${!key}")"    >> "${out}" || true
      [[ -n "${!secret:-}" ]] && printf '    secret_key: %s\n' "$(yaml_quote "${!secret}")" >> "${out}" || true
    done
  fi
  return 0
}

# YAML-quote a string by single-quoting and escaping single quotes.
yaml_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

submit_deployment() {
  bold "Submitting deployment"
  info "Bundle: ${IM_BUNDLE_URL}"

  local deployment_path="projects/${PROJECT_ID}/locations/${IM_LOCATION}/deployments/${DEPLOYMENT_NAME}"
  local inputs_file; inputs_file="$(mktemp -t platforma-im-inputs-XXXX.yaml)"
  trap 'rm -f "${inputs_file}"' EXIT
  build_inputs_file "${inputs_file}"

  info "Inputs file: ${inputs_file}"
  info "Inputs (with secrets redacted):"
  sed -E 's/(license_key|.*password|.*secret_key|htpasswd_content): .*/\1: "***"/' "${inputs_file}" | sed 's/^/    /'

  if gcloud infra-manager deployments describe "${DEPLOYMENT_NAME}" \
       --location="${IM_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    bold "Updating existing deployment ${DEPLOYMENT_NAME}…"
  else
    bold "Creating deployment ${DEPLOYMENT_NAME}…"
  fi

  gcloud infra-manager deployments apply "${deployment_path}" \
    --gcs-source="${IM_BUNDLE_URL}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --input-values-file="${inputs_file}" \
    --quiet

  echo
}

# -----------------------------------------------------------------------------
# Wait for completion
# -----------------------------------------------------------------------------

wait_for_completion() {
  bold "Waiting for deployment to settle (~15-25 min)"
  local last_state=""
  while :; do
    local state
    state="$(gcloud infra-manager deployments describe "${DEPLOYMENT_NAME}" \
              --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
              --format='value(state)' 2>/dev/null || echo UNKNOWN)"
    if [[ "${state}" != "${last_state}" ]]; then
      info "$(date +%H:%M:%S) state: ${state}"
      last_state="${state}"
    fi
    case "${state}" in
      ACTIVE) green "Deployment ACTIVE."; return 0 ;;
      FAILED) red   "Deployment FAILED. Inspect:"; \
              red   "  gcloud infra-manager deployments describe ${DEPLOYMENT_NAME} --location=${IM_LOCATION} --project=${PROJECT_ID}"; \
              return 1 ;;
      DELETED|SUSPENDED) red "Unexpected state ${state}"; return 1 ;;
    esac
    sleep 30
  done
}

# -----------------------------------------------------------------------------
# Final outputs
# -----------------------------------------------------------------------------

print_outputs() {
  bold "Deployment outputs"
  gcloud infra-manager deployments describe "${DEPLOYMENT_NAME}" \
    --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
    --format='value(terraformBlueprint.outputValues)' || true

  echo
  green "Done."
  echo
  bold "Connect the Platforma Desktop App"
  cat <<EOF
  1. Wait for the TLS cert to provision (5-15 min after deploy):
     gcloud certificate-manager certificates describe ${DEPLOYMENT_NAME}-cluster-cert \\
       --location=global --project=${PROJECT_ID}
     (Status should be ACTIVE.)

  2. Get your admin password:
     gcloud secrets versions access latest \\
       --secret=${DEPLOYMENT_NAME}-cluster-admin-password --project=${PROJECT_ID}

     Or open: https://console.cloud.google.com/security/secret-manager/secret/${DEPLOYMENT_NAME}-cluster-admin-password/versions?project=${PROJECT_ID}

  3. Open the Platforma Desktop App, click "Add Connection" → "Remote Server",
     enter https://${DOMAIN_NAME}, log in as 'platforma' with the password from step 2.
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  bold "Platforma on GCP — Infrastructure Manager installer"
  echo "Bundle version: ${IM_BUNDLE_VERSION}"
  echo

  preflight
  collect_inputs
  detect_existing_quota_prefs
  ensure_im_service_account

  bold "Review"
  cat <<EOF
  Project:         ${PROJECT_ID}
  Region:          ${REGION}  (zone ${REGION}-${ZONE_SUFFIX})
  Deployment:      ${DEPLOYMENT_NAME}  (in IM location ${IM_LOCATION})
  Size:            ${DEPLOYMENT_SIZE}
  Domain:          https://${DOMAIN_NAME}
  DNS zone:        ${DNS_ZONE_NAME}
  Demo library:    ${ENABLE_DEMO}
  Contact email:   ${CONTACT_EMAIL}
  IM service acct: ${IM_SA_EMAIL}
  Bundle:          ${IM_BUNDLE_URL}

EOF
  read -r -p "Proceed? [y/N] " confirm
  case "${confirm}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
  echo

  submit_deployment
  wait_for_completion
  print_outputs
}

main "$@"
