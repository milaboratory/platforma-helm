#!/usr/bin/env bash
# Local, no-cloud check that install.sh's tfvars generator and the
# terraform-platforma module agree on the Google-SSO client-secret wiring.
#
# Part A (bash+jq only, always runs): source install.sh, call the REAL
#   build_tfvars_json_platforma with Google env, assert the emitted tfvars
#   carry google_client_secret + auth_method=google.
# Part B (needs terraform|tofu): feed those tfvars to terraform-platforma and
#   `validate` the module — proves TF accepts install.sh's output shape.
#
# Usage: ./test-sso-tfvars.sh

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TF_DIR="$(cd -- "${SCRIPT_DIR}/.." &>/dev/null && pwd)"       # terraform-platforma
GCP_DIR="$(cd -- "${TF_DIR}/.." &>/dev/null && pwd)"          # infrastructure/gcp
INSTALL_SH="${GCP_DIR}/cloudshell/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }

SECRET_VALUE="GOCSPX-test-secret-value-123456789"

# Required scalars build_tfvars_json_full reads unconditionally (no :- defaults).
export AUTH_METHOD="google"
export GOOGLE_CLIENT_ID="12345-abc.apps.googleusercontent.com"
export GOOGLE_CLIENT_SECRET="${SECRET_VALUE}"
export PROJECT_ID="test-project"
export REGION="europe-west1"
export ZONE_SUFFIX="b"
export DEPLOYMENT_NAME="sso-test"
export DEPLOYMENT_SIZE="small"
export DOMAIN_NAME="sso-test.example.com"
export DNS_ZONE_NAME="example-zone"
export CONTACT_EMAIL="ops@example.com"
export LICENSE_KEY="TEST-LICENSE"
export ENABLE_DEMO="true"
export INFRA_OUT_GCS_BUCKET="test-bucket"
export INFRA_OUT_FILESTORE_INSTANCE_NAME="test-fs"
# In a real run prestage_master_secret sets this; required by terraform-platforma.
export MASTER_SECRET_SECRET_ID="projects/test/secrets/master/versions/1"

# Array populated by collect_data_libraries in a real run; empty here (no extra
# libraries). Not exportable — set in-shell so the sourced builder sees it.
DATA_LIBRARIES_BUILT=()

# --- Part A: install.sh generator -------------------------------------------
# shellcheck source=/dev/null
source "${INSTALL_SH}"

TFVARS="${TMP}/platforma.auto.tfvars.json"
build_tfvars_json_platforma "${TFVARS}"

jq -e '.auth_method == "google"' "${TFVARS}" >/dev/null \
  || fail "auth_method != google in generated tfvars"
jq -e --arg v "${SECRET_VALUE}" '.google_client_secret == $v' "${TFVARS}" >/dev/null \
  || fail "google_client_secret missing/wrong in generated tfvars"
jq -e '.google_client_id != null and .google_client_id != ""' "${TFVARS}" >/dev/null \
  || fail "google_client_id missing in generated tfvars"
ok "install.sh emits google_client_secret + auth_method=google"

# --- Part B: terraform consumes it ------------------------------------------
TF_BIN="$(command -v tofu || command -v terraform || true)"
if [[ -z "${TF_BIN}" ]]; then
  printf '\033[33m! skipping terraform validate — no tofu/terraform on PATH\033[0m\n'
  ok "Part A passed (generator side)"
  exit 0
fi

# Run in a temp copy so tofu init/validate never touches the tracked module
# (init would otherwise rewrite .terraform.lock.hcl on every run).
WORK="${TMP}/tf"
mkdir -p "${WORK}/tests"
cp "${TF_DIR}"/*.tf "${WORK}/"
cp "${TF_DIR}"/tests/*.tftest.hcl "${WORK}/tests/"
cp "${TFVARS}" "${WORK}/zz-test.auto.tfvars.json"

( cd "${WORK}" && "${TF_BIN}" init -backend=false -input=false >/dev/null ) \
  || fail "terraform init failed"

# validate: module accepts install.sh's tfvars shape
( cd "${WORK}" && "${TF_BIN}" validate ) \
  || fail "terraform validate failed on install.sh-generated tfvars"
ok "terraform-platforma validates with install.sh's tfvars"

# test: value-flow — google_client_secret -> secret + clientSecret.secretName
( cd "${WORK}" && "${TF_BIN}" test ) \
  || fail "tofu test failed — google_client_secret did not wire through"
ok "tofu test: google_client_secret wires to clientSecret.secretName"

ok "combined install.sh ↔ terraform check passed"
