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
IM_BUNDLE_VERSION="${IM_BUNDLE_VERSION:-dev-787bc64}"
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
  prompt_var       DEPLOYMENT_NAME    "Deployment name (lowercase letters/digits/dashes)" "platforma"
  prompt_var       IM_LOCATION        "IM deployment region"                              "${IM_LOCATION_DEFAULT}"
  prompt_var       REGION             "GCP region for the cluster"                        "europe-west1"
  prompt_var       ZONE_SUFFIX        "Zone suffix (a/b/c/d) for zonal resources"         "b"
  prompt_var       DEPLOYMENT_SIZE    "Deployment size (small|medium|large|xlarge)"       "small"
  prompt_var       DOMAIN_NAME        "Domain for the Platforma URL (e.g. platforma.example.com)"
  prompt_var       DNS_ZONE_NAME      "Cloud DNS managed zone name controlling that domain"
  prompt_var       CONTACT_EMAIL      "Email for quota/notification mail"                 "$(gcloud config get-value account 2>/dev/null || echo '')"
  prompt_var       ENABLE_DEMO        "Enable MiLaboratories demo data library? (true|false)" "true"
  prompt_secret_var LICENSE_KEY       "Platforma license key (E-…)"
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

build_input_values() {
  # Comma-separated key=value pairs for --input-values. Quote nothing — IM
  # parses by splitting on commas first then '='.
  cat <<EOF | tr '\n' ',' | sed 's/,$//'
project_id=${PROJECT_ID}
region=${REGION}
zone_suffix=${ZONE_SUFFIX}
cluster_name=${DEPLOYMENT_NAME}-cluster
deployment_size=${DEPLOYMENT_SIZE}
ingress_enabled=true
domain_name=${DOMAIN_NAME}
dns_zone_name=${DNS_ZONE_NAME}
contact_email=${CONTACT_EMAIL}
license_key=${LICENSE_KEY}
enable_demo_data_library=${ENABLE_DEMO}
EOF
}

submit_deployment() {
  bold "Submitting deployment"
  info "Bundle: ${IM_BUNDLE_URL}"

  local deployment_path="projects/${PROJECT_ID}/locations/${IM_LOCATION}/deployments/${DEPLOYMENT_NAME}"
  local input_values; input_values="$(build_input_values)"

  if gcloud infra-manager deployments describe "${DEPLOYMENT_NAME}" \
       --location="${IM_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    bold "Updating existing deployment ${DEPLOYMENT_NAME}…"
  else
    bold "Creating deployment ${DEPLOYMENT_NAME}…"
  fi

  gcloud infra-manager deployments apply "${deployment_path}" \
    --gcs-source="${IM_BUNDLE_URL}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --input-values="${input_values}" \
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
