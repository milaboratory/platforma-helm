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

# Per-run temp directory + cleanup. Created lazily on first reference; we
# initialise it here so any function in the script can use ${INSTALL_TMPDIR}
# and rely on EXIT trap cleanup without each function maintaining its own.
INSTALL_TMPDIR="$(mktemp -d -t platforma-im-XXXX)"
trap 'rm -rf "${INSTALL_TMPDIR}"' EXIT

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Source layout: this script lives at infrastructure/gcp/cloudshell/install.sh
# inside the platforma-helm repo. The TF module + chart are siblings (resolved
# below). The IM deployment source bundle is assembled from these locally —
# no remote tarball, no bucket, no publishing workflow. Users (or Cloud Shell)
# get the right version by cloning the repo at the desired ref:
#   - main (default for Cloud Shell button)  → latest
#   - tag  (e.g. v3.3.10, matching the chart version) → pinned release
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GCP_DIR="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"             # infrastructure/gcp
REPO_ROOT="$(cd -- "${GCP_DIR}/../.." &>/dev/null && pwd)"           # platforma-helm

# Two-stage deployment: install.sh submits the infra module first (cluster,
# IAM, network, storage, certmap), waits for it, reads its outputs, then
# submits the platforma module (Kueue, AppWrapper, Platforma chart, secrets,
# Gateway). The platforma module routes its k8s/helm/kubectl providers
# through data.google_container_cluster.primary, so by the time it plans
# the cluster already exists and the provider config resolves cleanly —
# sidesteps the kubectl-2.4 eager-validation chicken-and-egg the monolithic
# module hit.
BUNDLE_INFRA_TF_DIR="${GCP_DIR}/terraform-infra"
BUNDLE_PLATFORMA_TF_DIR="${GCP_DIR}/terraform-platforma"
BUNDLE_CHART_DIR="${REPO_ROOT}/charts/platforma"

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
  # Calling conventions:
  #   prompt_var NAME "prompt"            → required (empty input rejected)
  #   prompt_var NAME "prompt" "default"  → has default; empty input → default
  #   prompt_var NAME "prompt" ""         → optional (empty input accepted as "")
  local name="$1"; local prompt="$2"
  local default="" had_default=0
  if (( $# >= 3 )); then default="$3"; had_default=1; fi

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
    if (( had_default )); then
      # Empty default explicitly passed → optional; accept empty.
      printf -v "${name}" '%s' ""
      return
    fi
    red "${name} is required."; exit 1
  fi
  printf -v "${name}" '%s' "${input}"
}

# prompt_yn <prompt>  → exit 0 if user explicitly says yes, exit 1 if no.
# Loops on empty / invalid input rather than treating empty as a default,
# so users don't lose all their inputs if they accidentally hit Enter at
# the final confirmation.
prompt_yn() {
  local prompt="$1"
  while :; do
    local input
    read -r -p "  ${prompt} [y/n]: " input
    case "${input}" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) red "  Please answer y or n." ;;
    esac
  done
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
  # jq is used by detect_quota_decrease_collisions to parse the Cloud Quotas
  # API JSON output and filter by region. Cloud Shell always has it; local
  # runs on slim distros may not. Catching it here so the operator gets a
  # clear error early, not a silent no-op deep into the pre-flight quota
  # check.
  require_command jq

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

  # Provision the Infrastructure Manager service identity (
  # service-<num>@gcp-sa-config.iam.gserviceaccount.com). This SA backs IM's
  # internal storage; the FIRST IM call against a project fails with
  # "Creating the root Cloud Storage bucket failed: Not found ... Spanner:
  # Not found ServiceAccountInfoDataType" if the identity isn't created
  # explicitly — enabling the API alone isn't enough on a fresh project.
  info "Provisioning Infrastructure Manager service identity…"
  gcloud beta services identity create \
    --service=config.googleapis.com \
    --project="${PROJECT_ID}" --quiet >/dev/null || true

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

# Verify the chosen Cloud DNS zone is publicly resolvable — i.e. that the
# parent zone has actually delegated NS to it. Catches the common failure
# mode where the user creates a zone for a subdomain (e.g. gcp-test.example.com)
# but forgets to add NS records at the parent (example.com) pointing to the 4
# Cloud DNS nameservers. Without this check, install.sh runs all the way to
# Cert Manager, which then sits in PROVISIONING with AUTHORIZATION_ISSUE
# forever — costing the user 20+ minutes to discover the problem.
verify_dns_delegation() {
  bold "DNS delegation precheck"

  # Skip in non-ingress mode — no cert validation, no delegation needed.
  if [[ "${INGRESS_ENABLED:-true}" != "true" ]]; then
    info "Skipped (INGRESS_ENABLED=${INGRESS_ENABLED})"
    echo
    return 0
  fi

  if ! command -v dig &>/dev/null; then
    warn "dig not found — skipping DNS delegation check."
    warn "If the cert sticks in PROVISIONING after deploy, see infrastructure/gcp/domain-guide.md."
    echo
    return 0
  fi

  local zone_project="${DNS_ZONE_PROJECT:-${PROJECT_ID}}"
  local zone_info
  zone_info="$(gcloud dns managed-zones describe "${DNS_ZONE_NAME}" \
    --project="${zone_project}" --format=json 2>/dev/null || echo '{}')"
  local zone_dns_name expected_ns
  zone_dns_name="$(echo "${zone_info}" | jq -r '.dnsName // ""' | sed 's/\.$//')"
  expected_ns="$(echo "${zone_info}" | jq -r '.nameServers // [] | map(sub("\\.$";"")) | sort | .[]')"

  if [[ -z "${zone_dns_name}" ]]; then
    red "Could not describe zone ${DNS_ZONE_NAME} in project ${zone_project}."
    red "Check the zone exists and you have dns.managedZones.get permission."
    exit 1
  fi

  info "Zone:           ${DNS_ZONE_NAME}  (${zone_dns_name})"
  info "Expected NS:    $(echo "${expected_ns}" | head -1) (+3 more)"

  # Query the public DNS hierarchy for the zone's apex NS record. If the
  # parent didn't delegate, this returns empty (or, with some resolvers,
  # the NS of the parent — which still wouldn't match the Google ones).
  local actual_ns
  actual_ns="$(dig +short +time=5 +tries=2 NS "${zone_dns_name}" 2>/dev/null \
    | sed 's/\.$//' | sort)"

  # Print remediation guidance covering both cases — the user might own the
  # root domain (registrar points NS at Cloud DNS) or might be using a
  # subdomain delegated from a parent zone they control.
  print_dns_fix() {
    red "  Set these 4 nameservers as authoritative for '${zone_dns_name}':"
    while IFS= read -r ns; do red "    ${ns}"; done <<<"${expected_ns}"
    red ""
    red "  Where to set them:"
    red "    - If '${zone_dns_name}' is a domain you own at a registrar"
    red "      (GoDaddy, Namecheap, Cloudflare, Route53, Cloud Domains, etc.):"
    red "      update the domain's nameservers in the registrar admin."
    red "    - If '${zone_dns_name}' is a subdomain of a zone you already control:"
    red "      add an NS record for '${zone_dns_name%%.*}' on the parent zone."
    red ""
    red "  Step-by-step (Route53 / Cloudflare / GoDaddy / Namecheap / generic):"
    red "    infrastructure/gcp/domain-guide.md"
  }

  if [[ -z "${actual_ns}" ]]; then
    red "✗ ${zone_dns_name} returns no NS records from public DNS."
    red ""
    red "  Public resolvers can't find your Cloud DNS zone. Cert validation"
    red "  will fail and the cert will sit in PROVISIONING forever."
    red ""
    print_dns_fix
    red ""
    if prompt_yn "Proceed anyway (cert will not validate until you fix this)?"; then
      warn "Continuing without DNS delegation. Fix it within ~30 min of deploy."
      echo
      return 0
    fi
    exit 1
  fi

  # Compare actual to expected. Mismatch = NS points somewhere other than
  # this Cloud DNS zone (typical: registrar still points at default
  # nameservers, or zone exists in a different DNS provider too).
  if [[ "$(echo "${actual_ns}" | tr '\n' ' ')" != "$(echo "${expected_ns}" | tr '\n' ' ')" ]]; then
    red "✗ ${zone_dns_name} resolves to nameservers that don't match your Cloud DNS zone."
    red ""
    red "  Got from public DNS:"
    while IFS= read -r ns; do red "    ${ns}"; done <<<"${actual_ns}"
    red ""
    print_dns_fix
    red ""
    if prompt_yn "Proceed anyway (cert will not validate until you fix this)?"; then
      warn "Continuing with mismatched delegation."
      echo
      return 0
    fi
    exit 1
  fi

  green "  ✓ DNS delegation verified — public NS for ${zone_dns_name} matches Cloud DNS."
  echo
}

# Validate LDAP configuration before submitting the deployment. Three tiers:
#   1. Syntax — URL parses, ports are numeric, search rules well-formed,
#      mode-specific fields populated. Hard fail on issue.
#   2. TCP reachability from this machine — best effort, warning only.
#   3. LDAP bind from this machine — only in search-bind mode if `ldapsearch`
#      is available and credentials provided. Warning only.
#
# Important caveat: reachability from the user's machine != reachability from
# the GKE cluster. Cloud Shell often can't reach corporate LDAP at all, while
# the cluster (with proper VPC/firewall rules) can. We warn-only on network
# checks and tell the user that the cluster's view is what ultimately matters.
verify_ldap_config() {
  if [[ "${AUTH_METHOD:-}" != "ldap" ]]; then
    return 0
  fi

  bold "LDAP config precheck"

  # ---- Tier 1: syntax (hard fail) ----------------------------------------
  local server="${LDAP_SERVER:-}"
  if [[ -z "${server}" ]]; then
    red "✗ LDAP_SERVER is empty."; exit 1
  fi
  if [[ ! "${server}" =~ ^(ldap|ldaps)://([^/:[:space:]]+)(:([0-9]+))?/?$ ]]; then
    red "✗ LDAP_SERVER='${server}' is not a valid URL."
    red "  Expected: ldap://host[:port] or ldaps://host[:port]"
    exit 1
  fi
  local scheme="${BASH_REMATCH[1]}"
  local host="${BASH_REMATCH[2]}"
  local port="${BASH_REMATCH[4]:-}"
  if [[ -z "${port}" ]]; then
    if [[ "${scheme}" == "ldaps" ]]; then port=636; else port=389; fi
  fi
  info "Server:    ${scheme}://${host}:${port}"

  # StartTLS only makes sense on ldap:// (plain). On ldaps:// it's a misconfig.
  if [[ "${scheme}" == "ldaps" && "${LDAP_START_TLS:-false}" == "true" ]]; then
    warn "LDAP_START_TLS=true with ldaps:// — StartTLS is for plain ldap://; ignored on ldaps."
  fi

  # Direct-bind vs search-bind — exactly one should be configured.
  if [[ -n "${LDAP_BIND_DN:-}" ]]; then
    info "Mode:      direct-bind"
    if [[ "${LDAP_BIND_DN}" != *"%u"* ]]; then
      warn "LDAP_BIND_DN does not contain '%u' — direct-bind needs the username placeholder, e.g. 'cn=%u,ou=users,dc=...'"
    fi
    if [[ -n "${LDAP_SEARCH_RULES:-}${LDAP_SEARCH_USER:-}${LDAP_SEARCH_PASSWORD:-}" ]]; then
      red "✗ Both direct-bind (LDAP_BIND_DN) and search-bind fields are set."
      red "  Pick ONE mode — leave the other empty."
      exit 1
    fi
  else
    info "Mode:      search-bind"
    if [[ -z "${LDAP_SEARCH_RULES:-}" ]]; then
      red "✗ Neither LDAP_BIND_DN nor LDAP_SEARCH_RULES is set. Need one."
      exit 1
    fi
    # Each rule entry is "(filter)|baseDN", semicolon-separated.
    local IFS_BAK="${IFS}"
    IFS=';' read -ra rules <<<"${LDAP_SEARCH_RULES}"
    IFS="${IFS_BAK}"
    local rule
    for rule in "${rules[@]}"; do
      [[ -z "${rule}" ]] && continue
      if [[ ! "${rule}" =~ ^\([^|]+\)\|.+$ ]]; then
        red "✗ Search rule '${rule}' is malformed."
        red "  Expected format: '(filter)|baseDN'  e.g. '(uid=%u)|ou=users,dc=example,dc=com'"
        exit 1
      fi
      if [[ "${rule}" != *"%u"* ]]; then
        warn "Rule '${rule}' has no '%u' — username will not be substituted."
      fi
    done
  fi

  green "  ✓ Syntax OK"

  # ---- Tier 2: TCP reachability from this machine (warn only) ------------
  # Cloud Shell ships without nc; macOS has BSD nc; Linux distros often have
  # GNU netcat. Try a chain: python3 (universal on Cloud Shell + modern macOS)
  # → nc (if present) → bash /dev/tcp builtin (no clean timeout, but fast-fails
  # on most networks). At least one will work everywhere this script runs.
  local tcp_ok=1 tcp_method=""
  if command -v python3 &>/dev/null && python3 -c "
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()
except Exception:
    sys.exit(1)
" "${host}" "${port}" &>/dev/null; then
    tcp_method="python3"
  elif command -v nc &>/dev/null && nc -z -w 5 "${host}" "${port}" &>/dev/null; then
    tcp_method="nc"
  elif (bash -c "exec 3<>/dev/tcp/${host}/${port}") &>/dev/null; then
    tcp_method="bash"
  else
    tcp_ok=0
  fi

  if [[ ${tcp_ok} -eq 1 ]]; then
    green "  ✓ TCP ${host}:${port} reachable from this machine (${tcp_method})"
  else
    warn "TCP ${host}:${port} unreachable from this machine."
    warn "  This may be expected — Cloud Shell sits behind GCP NAT and often can't"
    warn "  reach corporate LDAP. What matters is reachability from the GKE cluster."
    warn "  If your LDAP is on a private network, ensure the cluster has VPC peering"
    warn "  / VPN / Private Service Connect to it before pods try to authenticate."
  fi

  # ---- Tier 2b: TLS handshake for ldaps:// (warn only) -------------------
  if [[ "${scheme}" == "ldaps" && ${tcp_ok} -eq 1 ]] && command -v openssl &>/dev/null; then
    local tls_out
    # openssl has its own connect timeout (-connect_timeout, but flag name
    # varies; rely on nc TCP probe above to gate this — once TCP works, the
    # handshake either completes fast or fails fast on its own).
    tls_out="$(echo | openssl s_client -connect "${host}:${port}" \
      -servername "${host}" -verify_return_error 2>&1 </dev/null || true)"
    if echo "${tls_out}" | grep -q "Verify return code: 0 (ok)"; then
      green "  ✓ TLS handshake OK (cert chain verified)"
    elif echo "${tls_out}" | grep -q "Verify return code:"; then
      local code; code="$(echo "${tls_out}" | grep "Verify return code:" | head -1)"
      warn "TLS connected but cert verification: ${code#*Verify return code: }"
      warn "  Self-signed / private-CA certs are common for corporate LDAP — the chart"
      warn "  supports trusting custom CAs via Helm values; not validated here."
    else
      warn "TLS handshake failed — server may not be ldaps:// on port ${port}."
    fi
  fi

  # ---- Tier 3: LDAP bind (search-bind mode only, warn only) --------------
  # Direct-bind can't be tested without a real user's password; skip there.
  if [[ -z "${LDAP_BIND_DN:-}" ]] && [[ -n "${LDAP_SEARCH_USER:-}" ]] \
     && [[ -n "${LDAP_SEARCH_PASSWORD:-}" ]] && command -v ldapsearch &>/dev/null \
     && [[ ${tcp_ok} -eq 1 ]]; then
    # Use the first rule's baseDN for the search base.
    local first_rule="${LDAP_SEARCH_RULES%%;*}"
    local base_dn="${first_rule#*|}"
    local starttls_args=()
    if [[ "${scheme}" == "ldap" && "${LDAP_START_TLS:-false}" == "true" ]]; then
      starttls_args=(-ZZ)
    fi
    local out rc
    out="$(LDAPTLS_REQCERT=allow ldapsearch -LLL -x -H "${server}" \
      "${starttls_args[@]}" \
      -D "${LDAP_SEARCH_USER}" -w "${LDAP_SEARCH_PASSWORD}" \
      -b "${base_dn}" -s base "(objectClass=*)" dn 2>&1)"
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
      green "  ✓ LDAP bind succeeded (search service account can read ${base_dn})"
    else
      warn "LDAP bind failed (rc=${rc}):"
      warn "  $(echo "${out}" | head -3 | tr '\n' ' ')"
      warn "  Could be wrong credentials, wrong base DN, or network — but if your"
      warn "  cluster has different network access than this machine, the cluster"
      warn "  may still bind successfully. Watch pod logs after deploy if unsure."
    fi
  elif [[ -n "${LDAP_BIND_DN:-}" ]]; then
    info "Bind test skipped — direct-bind mode (needs a real user's password)."
  fi

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
      # Three input modes (in priority order):
      #   HTPASSWD_CONTENT env var → use as-is
      #   HTPASSWD_FILE env var    → read from file
      #   Interactive prompt       → optional path, empty = auto-gen
      if [[ -n "${HTPASSWD_CONTENT:-}" ]]; then
        info "htpasswd content provided via env (${#HTPASSWD_CONTENT} bytes)."
      elif [[ -n "${HTPASSWD_FILE:-}" ]]; then
        if [[ ! -r "${HTPASSWD_FILE}" ]]; then
          red "HTPASSWD_FILE='${HTPASSWD_FILE}' is not readable."; exit 1
        fi
        HTPASSWD_CONTENT="$(< "${HTPASSWD_FILE}")"
        info "Read $(wc -l < "${HTPASSWD_FILE}" | tr -d ' ') line(s) from ${HTPASSWD_FILE}"
      else
        info "Generate htpasswd content with: htpasswd -nB <username> > ~/htpasswd"
        local htpasswd_path
        read -r -p "  Path to htpasswd file (empty = auto-generate, TESTING ONLY): " htpasswd_path
        htpasswd_path="${htpasswd_path/#\~/$HOME}"   # expand ~ for the user
        if [[ -n "${htpasswd_path}" ]]; then
          if [[ ! -r "${htpasswd_path}" ]]; then
            red "  File not found or unreadable: ${htpasswd_path}"; exit 1
          fi
          HTPASSWD_CONTENT="$(< "${htpasswd_path}")"
          green "  ✓ Read $(wc -l < "${htpasswd_path}" | tr -d ' ') line(s) from ${htpasswd_path}"
        else
          warn "Auto-generating random htpasswd password (TESTING ONLY)."
          warn "For production: generate with 'htpasswd -nB <user> > /tmp/htpasswd' and re-run."
        fi
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

  if [[ -n "${DATA_LIBRARIES_JSON:-}" ]]; then
    info "Custom data libraries provided via DATA_LIBRARIES_JSON env var (${#DATA_LIBRARIES_JSON} bytes)."
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
# Lookup table mirrors presets.tf — keep in sync on each preset change AND
# whenever NAP allowed-families changes. Adding a new family (e.g. c3, c3d)
# requires:
#   1. Append to nap_allowed_families in presets.tf
#   2. Add the matching N<FAMILY>-CPUS quota request in quotas.tf
#   3. Add the matching PRESET_<FAMILY>_CPUS array here + the preset key in
#      ALL_QUOTA_PRESET_KEYS + a case branch in required_for_preset_key()
# -----------------------------------------------------------------------------

declare -A PRESET_CPUS_GLOBAL=(    [small]=512  [medium]=1024 [large]=2048 [xlarge]=4096  )
declare -A PRESET_N2D_CPUS=(       [small]=512  [medium]=1024 [large]=2048 [xlarge]=4096  )
# N2_CPUS mirrors N2D — either family alone can host the full batch load
# if the other is stocked out. NAP picks whichever has stock at scale-up.
declare -A PRESET_N2_CPUS=(        [small]=512  [medium]=1024 [large]=2048 [xlarge]=4096  )
declare -A PRESET_PD_SSD_GB=(      [small]=4096 [medium]=8192 [large]=16384 [xlarge]=32768 )
declare -A PRESET_INSTANCES=(      [small]=32   [medium]=48   [large]=64   [xlarge]=128   )
declare -A PRESET_FILESTORE_GB=(   [small]=1024 [medium]=2048 [large]=4096 [xlarge]=8192  )

# Every quota preference terraform's quotas.tf creates. The TF resource names
# them platforma-<preset-key-with-dashes> (cpus_global → platforma-cpus-global).
# Authoritative list for the adopt-by-skip probe in detect_existing_quota_prefs:
# it MUST list every key in quotas.tf's quota_requests, or a missing one
# hard-collides ("QuotaPreference ... already exist") on any re-deploy into a
# project that previously ran Platforma.
ALL_QUOTA_PRESET_KEYS=(
  cpus_global
  n2d_cpus_region
  n2_cpus_region
  pd_ssd_region
  instances_region
  filestore_zonal_region
  in_use_addresses_region
)

# What value each preset key needs for the chosen DEPLOYMENT_SIZE.
required_for_preset_key() {
  local key="$1"
  case "${key}" in
    cpus_global)             echo "${PRESET_CPUS_GLOBAL[$DEPLOYMENT_SIZE]}"   ;;
    n2d_cpus_region)         echo "${PRESET_N2D_CPUS[$DEPLOYMENT_SIZE]}"      ;;
    n2_cpus_region)          echo "${PRESET_N2_CPUS[$DEPLOYMENT_SIZE]}"       ;;
    pd_ssd_region)           echo "${PRESET_PD_SSD_GB[$DEPLOYMENT_SIZE]}"     ;;
    instances_region)        echo "${PRESET_INSTANCES[$DEPLOYMENT_SIZE]}"     ;;
    filestore_zonal_region)  echo "${PRESET_FILESTORE_GB[$DEPLOYMENT_SIZE]}"  ;;
  esac
}

detect_existing_quota_prefs() {
  bold "Checking existing quota preferences"
  SKIP_QUOTA_REQUESTS_AUTO=()

  # The beta component is required and may not be installed in raw envs.
  if ! gcloud beta quotas preferences describe --help >/dev/null 2>&1; then
    info "Installing gcloud beta component (one-time)…"
    gcloud components install beta --quiet >/dev/null 2>&1 || true
  fi

  # If beta is still unusable (component-manager disabled, network/quota on the
  # components bucket, read-only runner FS), every describe below would fail
  # silently, the skip set would stay empty, and — because the Cloud Quotas API
  # has no DELETE — a re-deploy would then crash with "QuotaPreference ...
  # already exist". Surface it loudly with an actionable workaround instead of
  # silently probing 7 keys that all come back empty.
  if ! gcloud beta quotas preferences describe --help >/dev/null 2>&1; then
    warn "gcloud beta 'quotas preferences' unavailable — cannot detect existing quota preferences."
    warn "  → On a project that previously ran Platforma, terraform apply may fail with"
    warn "    'QuotaPreference ... already exist'. If so, re-run with ENABLE_QUOTA_AUTO_REQUEST=false."
    echo
    return 0
  fi

  # Probe each preference TF would create *by its exact resource name* via
  # 'describe' (deterministic NOT_FOUND-or-found). We used to parse 'list',
  # but an empty/non-JSON list response — or any quota id not in the lookup
  # table — silently yielded an empty skip set; and because the API has no
  # DELETE, the next 'terraform apply' then hard-failed with "QuotaPreference
  # ... already exist" on every preference. A per-name describe can't miss one.
  #
  # --billing-project is REQUIRED: cloudquotas.googleapis.com is billed to the
  # caller's quota project, and ADC in Cloud Shell often has none set (the
  # set-quota-project attempt earlier is best-effort and no-ops there). Without
  # it the call fails PERMISSION_DENIED/SERVICE_DISABLED against the wrong
  # consumer project, 2>/dev/null hides it, desc is empty for all keys, and we'd
  # skip nothing — reintroducing the collision. Pin it to the deployment project
  # (where the infra module enables the API). All preferences live at
  # locations/global (even region-dimensioned ones), so the bare name resolves.
  local has_warning=0 found=0
  local preset_key name desc preferred required
  for preset_key in "${ALL_QUOTA_PRESET_KEYS[@]}"; do
    name="platforma-${preset_key//_/-}"
    desc="$(gcloud beta quotas preferences describe "${name}" \
              --project="${PROJECT_ID}" --billing-project="${PROJECT_ID}" \
              --format=json 2>/dev/null)" || desc=""
    [[ -z "${desc}" ]] && continue   # absent → let terraform create it

    found=$(( found + 1 ))
    SKIP_QUOTA_REQUESTS_AUTO+=("${preset_key}")

    # Warn (don't block) when an existing preference is below what the chosen
    # deployment_size needs. Keys without a required-value mapping (e.g.
    # in_use_addresses_region) skip the comparison.
    required="$(required_for_preset_key "${preset_key}")"
    preferred="$(echo "${desc}" | jq -r '.quotaConfig.preferredValue // "0"' 2>/dev/null || echo 0)"
    if [[ -n "${required}" ]] && (( preferred < required )); then
      warn "Existing preference ${name}: value=${preferred} < required=${required} for ${DEPLOYMENT_SIZE}"
      warn "  → deployment will succeed but may run out of quota during job scale-up."
      warn "  → bump at: https://console.cloud.google.com/iam-admin/quotas?project=${PROJECT_ID}"
      has_warning=1
    elif [[ -n "${required}" ]]; then
      info "Existing preference ${name}: value=${preferred} ≥ required=${required} ✓ (skip auto-request)"
    else
      info "Existing preference ${name}: value=${preferred} (no preset threshold) — skip auto-request"
    fi
  done

  if (( found == 0 )); then
    info "No existing platforma-* quota preferences."
  else
    info "Found ${found} existing platforma-* preference(s) — skipping their creates."
  fi

  if (( has_warning > 0 )); then
    echo
    if ! prompt_yn "Existing quotas are below preset requirements. Continue anyway?"; then
      red "Aborted."; exit 1
    fi
  fi
  echo
}

# -----------------------------------------------------------------------------
# Normalize boolean inputs
# -----------------------------------------------------------------------------
# A handful of inputs are wired into the JSON tfvars via jq's --argjson,
# which requires syntactically-valid JSON. Booleans there are 'true' or
# 'false' (lowercase, no quotes). Operators commonly type 'True' / 'False'
# / 'yes' / '1' which would crash build_tfvars_json mid-run with a confusing
# jq parse error. Catch and reject those up-front; normalize accepted
# spellings to lowercase 'true' / 'false' so all downstream readers see the
# same canonical form.
#
# Variables covered (unset values pass through — downstream handles
# defaults explicitly):
#   ENABLE_QUOTA_AUTO_REQUEST   pre-flight check + tfvar
#   GCS_FORCE_DESTROY           tfvar
#   ENABLE_DEMO                 tfvar (set via prompt_var with default 'true')
#   LDAP_START_TLS              tfvar (set via prompt_var when AUTH_METHOD=ldap)
# -----------------------------------------------------------------------------

normalize_boolean_inputs() {
  local var val
  for var in ENABLE_QUOTA_AUTO_REQUEST GCS_FORCE_DESTROY ENABLE_DEMO LDAP_START_TLS; do
    val="${!var:-}"
    [[ -z "${val}" ]] && continue
    case "${val,,}" in
      true|yes|1)
        printf -v "${var}" '%s' 'true'
        ;;
      false|no|0)
        printf -v "${var}" '%s' 'false'
        ;;
      *)
        red "Invalid boolean for ${var}='${val}'."
        red "  Accepted: true / false (case-insensitive); 'yes' / 'no' / '1' / '0' also map to the right side."
        exit 1
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Pre-flight: warn when effective quotas would be decreased by >10%
# -----------------------------------------------------------------------------
# Cloud Quotas API rejects any QuotaPreference whose preferred_value would
# lower the current effective limit by more than 10% (FAILED_PRECONDITION /
# QUOTA_DECREASE_TOO_LARGE). The auto-request in quotas.tf is silent until
# 'terraform apply' fails mid-run, leaving the cluster partially-provisioned.
#
# Pre-checks each preset-mapped quota against its current effective limit
# and warns up-front when our preset's preferred_value would breach the
# 10% rule. Recommends ENABLE_QUOTA_AUTO_REQUEST=false in those cases.
#
# Skipped entirely when the user already opted out of auto-request.
# -----------------------------------------------------------------------------

# Map preset_key -> (service, quota_id, requires_region_dimension).
# Each preset_key listed here MUST have a matching case in
# required_for_preset_key() — otherwise the loop in
# detect_quota_decrease_collisions() will silently skip it (empty
# required => `continue`). The set below intentionally mirrors the keys
# defined in required_for_preset_key (PRESET_CPUS_GLOBAL etc.) — 5 quotas,
# excluding in_use_addresses_region (no preset table in install.sh yet;
# quotas.tf still requests it, but a collision on this one is rare and
# the postcondition error message points the operator straight at the
# right fix anyway).
declare -A QUOTA_PRESET_TO_SERVICE=(
  [cpus_global]="compute.googleapis.com"
  [n2d_cpus_region]="compute.googleapis.com"
  [n2_cpus_region]="compute.googleapis.com"
  [pd_ssd_region]="compute.googleapis.com"
  [instances_region]="compute.googleapis.com"
  [filestore_zonal_region]="file.googleapis.com"
)
declare -A QUOTA_PRESET_TO_QUOTAID=(
  [cpus_global]="CPUS-ALL-REGIONS-per-project"
  [n2d_cpus_region]="N2D-CPUS-per-project-region"
  [n2_cpus_region]="N2-CPUS-per-project-region"
  [pd_ssd_region]="SSD-TOTAL-GB-per-project-region"
  [instances_region]="INSTANCES-per-project-region"
  [filestore_zonal_region]="EnterpriseStorageGibPerRegion"
)
# Whether the quota's dimensions block needs region=${REGION}. Empty = global.
declare -A QUOTA_PRESET_TO_DIMREGION=(
  [cpus_global]=""
  [n2d_cpus_region]="1"
  [n2_cpus_region]="1"
  [pd_ssd_region]="1"
  [instances_region]="1"
  [filestore_zonal_region]="1"
)

# Fetch the current effective limit for a preset_key in the deployment's
# REGION. Echoes the numeric value, or empty when the API returns no info
# (typically a quota the project has never bumped — Cloud Quotas API
# returns the platform default in that case, so empty here usually means
# the API call itself failed or the project hasn't enabled the relevant
# service yet).
#
# Regional quotas return one dimensionsInfo per region the project has a
# preference in, ordered non-deterministically. We jq-filter to the
# matching REGION so we don't compare against an unrelated region's limit
# (which would produce both false positives and false negatives).
# Resolve which gcloud command path is available for Cloud Quotas reads.
# `gcloud quotas` (no prefix) was promoted to GA in SDK ~452 (Oct 2024);
# `gcloud beta quotas` has been available since late 2023. CloudShell
# environments occasionally ship an SDK older than 452, in which case the
# GA path errors with "Invalid choice: 'quotas'" and the pre-flight check
# silently fell through. Probe at startup, cache in QUOTAS_CLI (empty
# string = unavailable, skip pre-flight gracefully).
#
# This pre-flight is non-load-bearing — quotas.tf sets ignore_safety_checks
# to suppress the QUOTA_DECREASE_PERCENTAGE_TOO_HIGH safety check at apply
# time, so the install proceeds even if we can't read current limits here.
resolve_quotas_cli() {
  # QUOTAS_CLI_FLAVOR matters because the two CLI flavors take DIFFERENT
  # argument shapes (see fetch_effective_quota_for_preset_key):
  #   ga:   gcloud quotas info describe services/<svc>/quotaInfos/<id> ...
  #   beta: gcloud beta quotas info describe <id> --service=<svc> ...
  if gcloud quotas info describe --help >/dev/null 2>&1; then
    QUOTAS_CLI="gcloud quotas info describe"
    QUOTAS_CLI_FLAVOR="ga"
  elif gcloud beta quotas info describe --help >/dev/null 2>&1; then
    QUOTAS_CLI="gcloud beta quotas info describe"
    QUOTAS_CLI_FLAVOR="beta"
  else
    QUOTAS_CLI=""
    QUOTAS_CLI_FLAVOR="none"
  fi
}

fetch_effective_quota_for_preset_key() {
  local preset_key="$1"
  local service quota_id needs_region
  service="${QUOTA_PRESET_TO_SERVICE[${preset_key}]:-}"
  quota_id="${QUOTA_PRESET_TO_QUOTAID[${preset_key}]:-}"
  needs_region="${QUOTA_PRESET_TO_DIMREGION[${preset_key}]:-}"
  [[ -z "${service}" || -z "${quota_id}" ]] && return 0
  [[ -z "${QUOTAS_CLI:-}" ]] && return 0

  local json
  # The GA and beta CLIs take different argument shapes — build the right
  # one. The previous code always used the GA positional resource path,
  # which fails on beta-only environments ("argument --service: Must be
  # specified") → empty result → no auto-skip → downsizing apply fails.
  if [[ "${QUOTAS_CLI_FLAVOR}" == "beta" ]]; then
    json="$(gcloud beta quotas info describe "${quota_id}" \
      --service="${service}" \
      --project="${PROJECT_ID}" --billing-project="${PROJECT_ID}" \
      --format=json 2>/dev/null)" || return 0
  else
    json="$(gcloud quotas info describe \
      "services/${service}/quotaInfos/${quota_id}" \
      --project="${PROJECT_ID}" --billing-project="${PROJECT_ID}" \
      --format=json 2>/dev/null)" || return 0
  fi
  [[ -z "${json}" ]] && return 0

  local v=""
  if [[ -n "${needs_region}" ]]; then
    # Region-scoped quota: pick the dimensionsInfo whose dimensions.region
    # matches REGION.
    v="$(echo "${json}" | jq -r --arg r "${REGION}" \
      '.dimensionsInfos[]? | select(.dimensions.region == $r) | .details.value' \
      2>/dev/null | head -1)"
  fi
  if [[ -z "${v}" ]]; then
    # Fallback (global quotas, AND per-region quotas that report a single
    # dimensionsInfo with dimensions=null instead of a region key — notably
    # Filestore EnterpriseStorageGibPerRegion, which the region filter above
    # misses): take the no-region entry, then the first entry.
    v="$(echo "${json}" | jq -r \
      '.dimensionsInfos[]? | select(.dimensions == null or (.dimensions | has("region") | not)) | .details.value' \
      2>/dev/null | head -1)"
    [[ -z "${v}" ]] && v="$(echo "${json}" | jq -r '.dimensionsInfos[0]?.details.value' 2>/dev/null)"
  fi
  echo "${v}"
}

detect_quota_decrease_collisions() {
  if [[ "${ENABLE_QUOTA_AUTO_REQUEST:-true}" != "true" ]]; then
    # User already opted out globally — nothing to validate.
    return 0
  fi

  if [[ -z "${QUOTAS_CLI:-}" ]]; then
    bold "Checking for >10% quota-decrease collisions"
    warn "Skipped: gcloud quotas API unavailable (SDK older than ~452, neither 'gcloud quotas' nor 'gcloud beta quotas' resolves)."
    warn "To enable pre-flight check, run: gcloud components update — or open a fresh Cloud Shell session."
    info "Continuing: quotas.tf ignore_safety_checks handles QUOTA_DECREASE_PERCENTAGE_TOO_HIGH at apply time, so the deploy proceeds regardless."
    echo
    return 0
  fi

  bold "Checking for >10% quota-decrease collisions"

  # Build the set of preset_keys that terraform will skip via
  # var.skip_quota_requests. Two sources:
  #   - SKIP_QUOTA_REQUESTS_AUTO[] populated by detect_existing_quota_prefs
  #     when a user-managed QuotaPreference already exists for a quota.
  #   - SKIP_QUOTA_REQUESTS env var (comma-separated, set by power users).
  # For any preset_key in this set, terraform's google_cloud_quotas_quota_
  # preference resource is skipped → no >10%-decrease collision possible
  # for that quota. Warning about it would be a confusing false positive.
  local -A skip_set=()
  local k
  for k in "${SKIP_QUOTA_REQUESTS_AUTO[@]:-}"; do
    [[ -n "${k}" ]] && skip_set["${k}"]=1
  done
  if [[ -n "${SKIP_QUOTA_REQUESTS:-}" ]]; then
    local IFS=','
    for k in ${SKIP_QUOTA_REQUESTS}; do
      [[ -n "${k}" ]] && skip_set["${k}"]=1
    done
  fi

  local auto_skipped=0
  local preset_key required current

  for preset_key in "${!QUOTA_PRESET_TO_QUOTAID[@]}"; do
    if [[ -n "${skip_set[${preset_key}]:-}" ]]; then
      info "Skip ${QUOTA_PRESET_TO_QUOTAID[${preset_key}]}: already in skip_quota_requests (terraform won't request it)."
      continue
    fi

    required="$(required_for_preset_key "${preset_key}")"
    [[ -z "${required}" || "${required}" == "0" ]] && continue

    current="$(fetch_effective_quota_for_preset_key "${preset_key}" || echo "")"
    if [[ -z "${current}" || "${current}" == "0" ]]; then
      # No effective limit visible — either Cloud Quotas API not yet enabled
      # (preflight does that earlier; if still missing it's likely permission
      # related), or the quota genuinely has no preference yet. Either way,
      # no collision risk so skip silently.
      continue
    fi

    # Cloud Quotas rejects when the new effective would be <90% of current.
    # Equivalently: collision when current > required / 0.9, i.e.
    # current > required * 10/9. Exact integer form: current * 9 > required * 10.
    #
    # When this fires, auto-add the preset key to skip_quota_requests rather
    # than prompting the user. The project already has more headroom than the
    # preset would request, so skipping is a strict superset of what the
    # auto-request would have given us — the deploy proceeds cleanly without
    # the user needing to know that Cloud Quotas API rejects >10% decreases.
    if (( current * 9 > required * 10 )); then
      info "Auto-skip ${QUOTA_PRESET_TO_QUOTAID[${preset_key}]}${QUOTA_PRESET_TO_DIMREGION[${preset_key}]:+ (region=${REGION})}: project effective=${current} already exceeds preset=${required} by >10% (Cloud Quotas API would reject)."
      SKIP_QUOTA_REQUESTS_AUTO+=("${preset_key}")
      auto_skipped=$((auto_skipped + 1))
    fi
  done

  if (( auto_skipped > 0 )); then
    info "Auto-skipped ${auto_skipped} quota request(s) the project doesn't need."
    echo
  else
    info "No >10% decrease collisions — all quota requests will be submitted."
    echo
  fi
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

# Builds a JSON file at $1 containing the UNION of variables both modules
# accept. build_tfvars_json_infra / build_tfvars_json_platforma below
# project this document down to just the keys each module declares — TF
# warns (loudly) about undeclared variables, so we filter rather than
# pass the full set to both.
#
# Terraform auto-loads any *.auto.tfvars.json in its working directory, so
# the user-supplied values become deployment inputs without ever passing
# through gcloud's --input-values flag (which has no way to express list/
# object types like data_libraries or ldap_search_rules).
build_tfvars_json_full() {
  local out="$1"

  # Base scalars — start a JSON document via jq.
  local doc
  doc="$(jq -n \
    --arg     project_id     "${PROJECT_ID}" \
    --arg     region         "${REGION}" \
    --arg     zone_suffix    "${ZONE_SUFFIX}" \
    --arg     cluster_name   "${DEPLOYMENT_NAME}-cluster" \
    --arg     deployment_size "${DEPLOYMENT_SIZE}" \
    --argjson ingress_enabled true \
    --arg     domain_name    "${DOMAIN_NAME}" \
    --arg     dns_zone_name  "${DNS_ZONE_NAME}" \
    --arg     contact_email  "${CONTACT_EMAIL}" \
    --arg     license_key    "${LICENSE_KEY}" \
    --argjson enable_demo_data_library "${ENABLE_DEMO}" \
    --arg     auth_method    "${AUTH_METHOD}" \
    '{
       project_id:               $project_id,
       region:                   $region,
       zone_suffix:              $zone_suffix,
       cluster_name:             $cluster_name,
       deployment_size:          $deployment_size,
       ingress_enabled:          $ingress_enabled,
       domain_name:              $domain_name,
       dns_zone_name:            $dns_zone_name,
       contact_email:            $contact_email,
       license_key:              $license_key,
       enable_demo_data_library: $enable_demo_data_library,
       auth_method:              $auth_method
     }')"

  # Auth: htpasswd-content path
  if [[ "${AUTH_METHOD}" == "htpasswd" && -n "${HTPASSWD_CONTENT:-}" ]]; then
    doc="$(echo "${doc}" | jq --arg v "${HTPASSWD_CONTENT}" '. + {htpasswd_content: $v}')"
  fi

  # Auth: LDAP path
  if [[ "${AUTH_METHOD}" == "ldap" ]]; then
    doc="$(echo "${doc}" | jq \
      --arg     ldap_server      "${LDAP_SERVER}" \
      --argjson ldap_start_tls   "${LDAP_START_TLS}" \
      --arg     ldap_bind_dn     "${LDAP_BIND_DN}" \
      --arg     ldap_search_user "${LDAP_SEARCH_USER:-}" \
      '. + {
         ldap_server:      $ldap_server,
         ldap_start_tls:   $ldap_start_tls,
         ldap_bind_dn:     $ldap_bind_dn,
         ldap_search_user: $ldap_search_user
       }')"
    if [[ -n "${LDAP_SEARCH_PASSWORD:-}" ]]; then
      doc="$(echo "${doc}" | jq --arg v "${LDAP_SEARCH_PASSWORD}" '. + {ldap_search_password: $v}')"
    fi
    if [[ -n "${LDAP_SEARCH_RULES:-}" ]]; then
      local rules_json
      rules_json="$(printf '%s' "${LDAP_SEARCH_RULES}" | tr ';' '\n' | awk 'NF' | jq -R . | jq -s .)"
      doc="$(echo "${doc}" | jq --argjson v "${rules_json}" '. + {ldap_search_rules: $v}')"
    fi
  fi

  # enable_quota_auto_request — opt out of QuotaPreference creation entirely.
  # Set ENABLE_QUOTA_AUTO_REQUEST=false on long-lived projects whose quotas
  # are already above what the deployment_size preset requests; GCP rejects
  # any QuotaPreference that lowers an effective limit by >10%.
  if [[ -n "${ENABLE_QUOTA_AUTO_REQUEST:-}" ]]; then
    doc="$(echo "${doc}" | jq --argjson v "${ENABLE_QUOTA_AUTO_REQUEST}" '. + {enable_quota_auto_request: $v}')"
  fi

  # skip_quota_requests — auto-detected collisions + any user additions.
  local skip_list=("${SKIP_QUOTA_REQUESTS_AUTO[@]:-}")
  if [[ -n "${SKIP_QUOTA_REQUESTS:-}" ]]; then
    local IFS=','
    for k in ${SKIP_QUOTA_REQUESTS}; do skip_list+=("${k}"); done
  fi
  if (( ${#skip_list[@]} > 0 )); then
    local unique; unique="$(printf '%s\n' "${skip_list[@]}" | awk 'NF && !seen[$0]++')"
    if [[ -n "${unique}" ]]; then
      local skip_json; skip_json="$(printf '%s' "${unique}" | jq -R . | jq -s .)"
      doc="$(echo "${doc}" | jq --argjson v "${skip_json}" '. + {skip_quota_requests: $v}')"
    fi
  fi

  # GCS bucket force_destroy — set GCS_FORCE_DESTROY=true on dev/test
  # deployments so 'terraform destroy' (driven by the IM delete path) can
  # remove the primary bucket even when it still contains workspace results.
  # Production deployments leave the default (false) to protect user data.
  if [[ -n "${GCS_FORCE_DESTROY:-}" ]]; then
    doc="$(echo "${doc}" | jq --argjson v "${GCS_FORCE_DESTROY}" '. + {gcs_force_destroy: $v}')"
  fi

  # Platforma container image override — pin the binary to a specific tag,
  # e.g. a dev build from main pushed to the project's GAR for testing chart
  # changes against an unreleased platforma version.
  if [[ -n "${PLATFORMA_IMAGE_OVERRIDE:-}" ]]; then
    doc="$(echo "${doc}" | jq --arg v "${PLATFORMA_IMAGE_OVERRIDE}" '. + {platforma_image_override: $v}')"
  fi

  # Helm chart override — when both env vars are set, the deployment pulls the
  # chart from an OCI registry (typically the test GAR repo at
  # europe-west3-docker.pkg.dev/mik8s-euwe3-prod-gke-project/platforma) instead
  # of the chart bundled from the local checkout. submit_deployment() skips the
  # chart-bundling step when HELM_CHART_REPOSITORY is set.
  if [[ -n "${HELM_CHART_REPOSITORY:-}" ]]; then
    doc="$(echo "${doc}" | jq --arg v "${HELM_CHART_REPOSITORY}" '. + {helm_chart_repository: $v}')"
  fi
  if [[ -n "${PLATFORMA_CHART_VERSION:-}" ]]; then
    doc="$(echo "${doc}" | jq --arg v "${PLATFORMA_CHART_VERSION}" '. + {platforma_chart_version: $v}')"
  fi

  # Data libraries — power-user JSON env var wins, else build from prompts.
  if [[ -n "${DATA_LIBRARIES_JSON:-}" ]]; then
    doc="$(echo "${doc}" | jq --argjson v "${DATA_LIBRARIES_JSON}" '. + {data_libraries: $v}')"
  elif (( ${#DATA_LIBRARIES_BUILT[@]} > 0 )); then
    local libs="[]"
    local i
    for i in "${DATA_LIBRARIES_BUILT[@]}"; do
      local name="LIB_${i}_NAME"   type="LIB_${i}_TYPE"
      local bucket="LIB_${i}_BUCKET" prefix="LIB_${i}_PREFIX"
      local region="LIB_${i}_REGION" key="LIB_${i}_ACCESS_KEY" secret="LIB_${i}_SECRET_KEY"

      local lib
      lib="$(jq -n \
        --arg name       "${!name}" \
        --arg type       "${!type}" \
        --arg bucket     "${!bucket}" \
        --arg prefix     "${!prefix:-}" \
        --arg region     "${!region:-}" \
        --arg access_key "${!key:-}" \
        --arg secret_key "${!secret:-}" \
        '{name: $name, type: $type, bucket: $bucket}
         + (if $prefix     != "" then {prefix:     $prefix}     else {} end)
         + (if $region     != "" then {region:     $region}     else {} end)
         + (if $access_key != "" then {access_key: $access_key} else {} end)
         + (if $secret_key != "" then {secret_key: $secret_key} else {} end)')"
      libs="$(echo "${libs}" | jq --argjson lib "${lib}" '. + [$lib]')"
    done
    doc="$(echo "${doc}" | jq --argjson v "${libs}" '. + {data_libraries: $v}')"
  fi

  echo "${doc}" > "${out}"
}

# Project the full tfvars document to just the keys terraform-infra/
# declares. Drops any null/missing entries so we don't pass empty strings
# for vars the user didn't set.
#
# $1: path to write the projected JSON file.
build_tfvars_json_infra() {
  local out="$1"
  local full; full="$(mktemp)"
  build_tfvars_json_full "${full}"
  jq '{
    project_id, region, zone_suffix, cluster_name, deployment_size,
    vpc_name, subnet_nodes_cidr, subnet_pods_cidr, subnet_services_cidr,
    master_ipv4_cidr_block, enable_private_nodes,
    system_pool_machine_type, system_pool_node_count,
    ui_pool_machine_type, ui_pool_max_nodes,
    batch_pool_max_nodes_overrides, batch_pool_disk_size_gb,
    filestore_tier, workspace_capacity_gb, workspace_share_name,
    gcs_bucket_name, gcs_force_destroy,
    platforma_namespace, helm_release_name,
    data_libraries,
    ingress_enabled, domain_name, dns_zone_name, dns_zone_project,
    enable_google_batch,
    enable_quota_auto_request, contact_email, skip_quota_requests,
    kueue_max_job_cpu, kueue_max_job_memory,
    kueue_batch_queue_cpu, kueue_batch_queue_memory
  } | with_entries(select(.value != null))' "${full}" > "${out}"
  rm -f "${full}"
}

# Project the full tfvars document to just the keys terraform-platforma/
# declares, then patch in the two values that come from the infra
# module's outputs (gcs_bucket, filestore_instance_name) — install.sh
# fetches these via read_infra_outputs after the infra deployment settles.
#
# $1: path to write the projected JSON file.
# Reads globals: INFRA_OUT_GCS_BUCKET, INFRA_OUT_FILESTORE_INSTANCE_NAME.
build_tfvars_json_platforma() {
  local out="$1"
  local full; full="$(mktemp)"
  build_tfvars_json_full "${full}"
  jq --arg gcs_bucket            "${INFRA_OUT_GCS_BUCKET}" \
     --arg filestore_instance    "${INFRA_OUT_FILESTORE_INSTANCE_NAME}" \
     '{
        project_id, region, zone_suffix, cluster_name,
        platforma_namespace, helm_release_name, deployment_size,
        ingress_enabled, domain_name,
        kueue_max_job_cpu, kueue_max_job_memory,
        kueue_batch_queue_cpu, kueue_batch_queue_memory,
        batch_pool_max_nodes_overrides, ui_pool_max_nodes, workspace_capacity_gb,
        license_key, platforma_chart_version, helm_chart_repository,
        platforma_image_override, deploy_platforma,
        admin_username, auth_method, htpasswd_content,
        ldap_server, ldap_start_tls, ldap_bind_dn,
        ldap_search_rules, ldap_search_user, ldap_search_password,
        enable_demo_data_library, data_libraries
      }
      | with_entries(select(.value != null))
      | . + {gcs_bucket: $gcs_bucket, filestore_instance_name: $filestore_instance}' \
     "${full}" > "${out}"
  rm -f "${full}"
}

# submit_deployment <deployment_name> <bundle_tf_dir> <module> [bundle_chart]
#
# Args:
#   $1 deployment_name  — full IM deployment name (e.g. "${DEPLOYMENT_NAME}-infra")
#   $2 bundle_tf_dir    — local path to the module's .tf files
#   $3 module           — "infra" or "platforma" (selects tfvars projection)
#   $4 bundle_chart     — "true" to copy the Platforma chart into the bundle
#                         (only meaningful for the platforma module and only
#                         when HELM_CHART_REPOSITORY is empty)
submit_deployment() {
  local deployment_name="$1"
  local bundle_tf_dir="$2"
  local module="$3"
  local bundle_chart="${4:-false}"

  bold "Submitting deployment ${deployment_name} (${module})"

  local source_ref
  source_ref="$(git -C "${REPO_ROOT}" describe --tags --always --dirty 2>/dev/null || echo "(unknown)")"
  info "Source: ${bundle_tf_dir} @ ${source_ref}"

  local deployment_path="projects/${PROJECT_ID}/locations/${IM_LOCATION}/deployments/${deployment_name}"
  local work_dir="${INSTALL_TMPDIR}/im-bundle-${module}"
  rm -rf "${work_dir}"
  mkdir -p "${work_dir}"

  # Assemble the IM source bundle from the local checkout:
  #   - drop backend.tf (IM manages state internally)
  #   - drop dev-only files
  #   - keep .terraform.lock.hcl (IM honors it for reproducible provider
  #     versions — previously stripped, which caused IM to silently pull
  #     newer provider patches; alekc/kubectl 2.4.0 broke the old module
  #     this way).
  # For the platforma module, also bundle the chart at terraform-platforma/
  # platforma/ and rewrite the chart path in app.tf for the IM context.
  # When HELM_CHART_REPOSITORY is set, the helm_chart_repository tfvar
  # makes app.tf pull the chart from OCI instead.
  info "Assembling bundle from local checkout…"
  cp -R "${bundle_tf_dir}/." "${work_dir}/"
  rm -f  "${work_dir}/backend.tf" "${work_dir}/terraform.tfvars" \
         "${work_dir}/tfplan" "${work_dir}/errored.tfstate"
  rm -rf "${work_dir}/.terraform"

  if [[ "${bundle_chart}" == "true" ]] && [[ -z "${HELM_CHART_REPOSITORY:-}" ]]; then
    cp -R "${BUNDLE_CHART_DIR}" "${work_dir}/platforma"
    if grep -q '"${path.module}/../../../charts/platforma"' "${work_dir}/app.tf"; then
      sed -i.bak 's|"${path.module}/../../../charts/platforma"|"${path.module}/platforma"|' "${work_dir}/app.tf"
      rm -f "${work_dir}/app.tf.bak"
    fi
  elif [[ "${bundle_chart}" == "true" ]]; then
    info "Chart source: OCI registry ${HELM_CHART_REPOSITORY} (version ${PLATFORMA_CHART_VERSION:-<chart default>})"
  fi

  # Embed user-supplied inputs as a tfvars file the bundle picks up
  # automatically (Terraform auto-loads any *.auto.tfvars.json).
  case "${module}" in
    infra)     build_tfvars_json_infra     "${work_dir}/inputs.auto.tfvars.json" ;;
    platforma) build_tfvars_json_platforma "${work_dir}/inputs.auto.tfvars.json" ;;
    *) red "submit_deployment: unknown module '${module}'"; exit 1 ;;
  esac

  info "Inputs (with secrets redacted):"
  jq 'to_entries
      | map(if (.key | test("license_key|password|secret_key|htpasswd_content")) then .value = "***" else . end)
      | from_entries' "${work_dir}/inputs.auto.tfvars.json" | sed 's/^/    /'

  # Detect a previous deployment in a state that 'apply' can't recover from
  # (FAILED with no successful revision — the apply path tries to read the
  # latestRevision and crashes with IndexError). We delete + recreate.
  local existing_state existing_revision
  existing_state="$(gcloud infra-manager deployments describe "${deployment_name}" \
    --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
    --format='value(state)' 2>/dev/null || echo NOTFOUND)"
  existing_revision="$(gcloud infra-manager deployments describe "${deployment_name}" \
    --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
    --format='value(latestRevision)' 2>/dev/null || echo "")"

  case "${existing_state}" in
    NOTFOUND)
      bold "Creating deployment ${deployment_name}…"
      ;;
    ACTIVE|FAILED)
      if [[ -z "${existing_revision}" ]]; then
        warn "Existing deployment is in ${existing_state} state with no revision (initial creation never succeeded). Deleting before recreating…"
        gcloud infra-manager deployments delete "${deployment_name}" \
          --location="${IM_LOCATION}" --project="${PROJECT_ID}" --quiet
        bold "Creating deployment ${deployment_name}…"
      else
        bold "Updating existing deployment ${deployment_name} (state: ${existing_state})…"
      fi
      ;;
    CREATING|UPDATING|DELETING)
      # IM rejects concurrent operations on the same deployment with a
      # confusing 'ABORTED' error. Tell the operator to wait rather than
      # firing off an apply that's guaranteed to fail.
      red   "Deployment ${deployment_name} is busy (state: ${existing_state})."
      red   "  Wait for the in-flight operation to finish, then re-run install.sh."
      red   "  Watch progress: https://console.cloud.google.com/infra-manager/deployments/details/${IM_LOCATION}/${deployment_name}?project=${PROJECT_ID}"
      exit 1
      ;;
    *)
      bold "Creating/updating deployment ${deployment_name} (state: ${existing_state})…"
      ;;
  esac

  # Print monitoring URLs BEFORE the long-running gcloud apply call. If the
  # Cloud Shell session times out / disconnects during the ~20 min provision,
  # the user can come back and watch progress / errors here.
  echo
  bold "Monitor progress (open in browser if Cloud Shell disconnects):"
  cat <<EOF
  Infrastructure Manager:  https://console.cloud.google.com/infra-manager/deployments/details/${IM_LOCATION}/${deployment_name}?project=${PROJECT_ID}
  Cloud Build (TF runs):   https://console.cloud.google.com/cloud-build/builds?project=${PROJECT_ID}
EOF
  echo

  gcloud infra-manager deployments apply "${deployment_path}" \
    --local-source="${work_dir}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --quiet

  echo
}

# -----------------------------------------------------------------------------
# Wait for completion
# -----------------------------------------------------------------------------

# wait_for_completion <deployment_name>
wait_for_completion() {
  local deployment_name="$1"
  bold "Waiting for ${deployment_name} to settle"
  local last_state=""
  while :; do
    local state
    state="$(gcloud infra-manager deployments describe "${deployment_name}" \
              --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
              --format='value(state)' 2>/dev/null || echo UNKNOWN)"
    if [[ "${state}" != "${last_state}" ]]; then
      info "$(date +%H:%M:%S) state: ${state}"
      last_state="${state}"
    fi
    case "${state}" in
      ACTIVE) green "Deployment ${deployment_name} ACTIVE."; return 0 ;;
      FAILED) red   "Deployment ${deployment_name} FAILED. Inspect:"; \
              red   "  gcloud infra-manager deployments describe ${deployment_name} --location=${IM_LOCATION} --project=${PROJECT_ID}"; \
              return 1 ;;
      DELETED|SUSPENDED) red "Unexpected state ${state}"; return 1 ;;
    esac
    sleep 30
  done
}

# read_infra_outputs — discover the GCS bucket name and Filestore instance
# name that the infra module created, so build_tfvars_json_platforma can
# pass them to the platforma module.
#
# Previously this called 'gcloud infra-manager deployments describe' and
# parsed terraformBlueprint.outputValues — but that field only carries the
# bundle gcsSource; TF outputs live on the revision object, not the
# deployment object, and the gcloud surface for reading them through the
# deployment varies between SDK versions. Switching to direct GCP-native
# discovery removes that fragility entirely:
#
#   filestore_instance_name is fully deterministic from cluster_name:
#     "${cluster_name}-workspace"  (matches terraform-infra/storage.tf)
#
#   gcs_bucket can be either user-provided (var.gcs_bucket_name) or
#     auto-generated with a random suffix. terraform-infra/storage.tf
#     labels every bucket with cluster=${cluster_name}, so we list and
#     filter on that label — unambiguous within a project.
read_infra_outputs() {
  local deployment_name="$1"
  bold "Discovering infra outputs"

  # CLUSTER_NAME is set in build_tfvars_json_full as "${DEPLOYMENT_NAME}-cluster".
  local cluster_name="${DEPLOYMENT_NAME}-cluster"

  INFRA_OUT_FILESTORE_INSTANCE_NAME="${cluster_name}-workspace"

  local matches matches_count
  matches="$(gcloud storage buckets list \
    --project="${PROJECT_ID}" \
    --filter="labels.cluster=${cluster_name}" \
    --format='value(name)' 2>/dev/null)"
  matches_count="$(printf '%s' "${matches}" | grep -c . || true)"

  if (( matches_count == 0 )); then
    red "Could not find GCS bucket labelled cluster=${cluster_name} in project ${PROJECT_ID}."
    red "  The infra deployment created the bucket but discovery failed — check:"
    red "    gcloud storage buckets list --project=${PROJECT_ID} --filter='labels.cluster=${cluster_name}'"
    red "  (If empty, the infra deploy may have rolled back or the label is missing.)"
    return 1
  fi
  if (( matches_count > 1 )); then
    # Ambiguous: a previous deploy that failed to tear down cleanly can
    # leave a stale bucket with the same label. Refuse rather than pick
    # one — picking the wrong one points the platforma module at the
    # wrong storage and corrupts state silently.
    red "Multiple GCS buckets match labels.cluster=${cluster_name}:"
    printf '%s\n' "${matches}" | sed 's/^/  /' >&2
    red "  Ambiguous — delete the stale bucket(s) before redeploying, or"
    red "  override with var.gcs_bucket_name in the infra deploy."
    return 1
  fi
  INFRA_OUT_GCS_BUCKET="${matches}"

  info "gcs_bucket:              ${INFRA_OUT_GCS_BUCKET}"
  info "filestore_instance_name: ${INFRA_OUT_FILESTORE_INSTANCE_NAME}"
  echo

  # Unused note: deployment_name is kept as a parameter so the function
  # signature documents the dependency on the infra deploy having settled,
  # even though discovery happens via the GCP-side resource queries above.
  : "${deployment_name}"
}

# -----------------------------------------------------------------------------
# Final outputs
# -----------------------------------------------------------------------------

# print_outputs <platforma_deployment_name>
# Reads outputs from the platforma IM deployment (post-deploy steps, URLs,
# port-forward command — generated by terraform-platforma/outputs.tf).
print_outputs() {
  local deployment_name="$1"
  bold "Deployment outputs"
  gcloud infra-manager deployments describe "${deployment_name}" \
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
  local source_ref
  source_ref="$(git -C "${REPO_ROOT}" describe --tags --always --dirty 2>/dev/null || echo "(unknown)")"
  echo "Source: ${REPO_ROOT} @ ${source_ref}"
  echo

  preflight
  resolve_quotas_cli
  collect_inputs
  normalize_boolean_inputs
  verify_dns_delegation
  verify_ldap_config
  detect_existing_quota_prefs
  detect_quota_decrease_collisions
  ensure_im_service_account

  # Two-stage deployment names — both managed by IM in the same location.
  local infra_deployment="${DEPLOYMENT_NAME}-infra"
  local platforma_deployment="${DEPLOYMENT_NAME}-platforma"

  bold "Review"
  cat <<EOF
  Project:         ${PROJECT_ID}
  Region:          ${REGION}  (zone ${REGION}-${ZONE_SUFFIX})
  Deployments:     ${infra_deployment}, ${platforma_deployment}  (in IM location ${IM_LOCATION})
  Size:            ${DEPLOYMENT_SIZE}
  Domain:          https://${DOMAIN_NAME}
  DNS zone:        ${DNS_ZONE_NAME}
  Auth method:     ${AUTH_METHOD}
  Demo library:    ${ENABLE_DEMO}
  Contact email:   ${CONTACT_EMAIL}
  IM service acct: ${IM_SA_EMAIL}
  Source:          ${REPO_ROOT} @ ${source_ref}

EOF
  if ! prompt_yn "Proceed?"; then
    echo "Aborted."; exit 0
  fi
  echo

  # Stage 1 — cluster + everything except k8s/helm/kubectl resources.
  submit_deployment "${infra_deployment}" "${BUNDLE_INFRA_TF_DIR}" "infra" "false"
  wait_for_completion "${infra_deployment}"
  read_infra_outputs  "${infra_deployment}"

  # Stage 2 — Kueue, AppWrapper, Platforma chart, secrets, Gateway/HTTPRoute.
  # By now the cluster exists, so data.google_container_cluster.primary
  # resolves at plan time and the k8s/helm/kubectl providers configure
  # without the kubectl-2.4 eager-validation chicken-and-egg.
  submit_deployment "${platforma_deployment}" "${BUNDLE_PLATFORMA_TF_DIR}" "platforma" "true"
  wait_for_completion "${platforma_deployment}"

  print_outputs "${platforma_deployment}"
}

main "$@"
