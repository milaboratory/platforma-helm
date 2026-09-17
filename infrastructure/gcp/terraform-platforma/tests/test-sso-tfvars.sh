#!/usr/bin/env bash
# Local, no-cloud check that install.sh's tfvars generator and the
# terraform-platforma module agree on the login-source wiring.
#
# Part A (bash+jq only, always runs): one subshell per case below, each
#   exporting that case's source variables, sourcing install.sh, and calling
#   the REAL build_tfvars_json_platforma into its own temp file.
# Part B (needs terraform|tofu): feeds the multi-source case's tfvars to
#   terraform-platforma and `validate`/`test`s the module.
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

# Required scalars build_tfvars_json_full reads unconditionally (no :- defaults).
export_common_vars() {
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
  # Array populated by collect_data_libraries in a real run; empty here (no
  # extra libraries). Not exportable — set in-shell so the sourced builder
  # sees it.
  DATA_LIBRARIES_BUILT=()
}

MULTI_SOURCE_TFVARS="${TMP}/multi-source.auto.tfvars.json"

# --- Multi-source run names every source's variable -------------------------
(
  export_common_vars
  export SSO_PROVIDER="google"
  export GOOGLE_CLIENT_ID="12345-abc.apps.googleusercontent.com"
  export GOOGLE_CLIENT_SECRET="GOCSPX-test-secret-value-123456789"
  export LDAP_SERVER="ldaps://ldap.example.com:636"
  export LDAP_START_TLS="false"
  export LDAP_BIND_DN=""
  export LDAP_SEARCH_RULES="(uid=%u)|ou=users,dc=example,dc=com"
  export LDAP_SEARCH_USER="cn=svc,dc=example,dc=com"
  export LDAP_SEARCH_PASSWORD="ldap-search-secret"
  export ENABLE_LOCAL_USERS="true"
  export HTPASSWD_CONTENT="alice:\$2y\$05\$abc"
  export SSO_ADMIN_USERS="alice@example.com;^ops-.*\$"
  export LDAP_ADMIN_USERS="bob@example.com"
  export LOCAL_ADMIN_USERS="carol"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  build_tfvars_json_platforma "${MULTI_SOURCE_TFVARS}"
) || fail "the multi-source run did not exit 0"

jq -e '.sso_provider == "google"' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "sso_provider != google in generated tfvars"
jq -e '.enable_local_users == true' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "enable_local_users != true in generated tfvars"
jq -e '.ldap_server == "ldaps://ldap.example.com:636"' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "ldap_server missing/wrong in generated tfvars"
jq -e '.htpasswd_content != null and .htpasswd_content != ""' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "htpasswd_content missing in generated tfvars"
jq -e '.sso_admin_users == "alice@example.com;^ops-.*$"' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "sso_admin_users not passed through verbatim"
jq -e '.ldap_admin_users == "bob@example.com"' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "ldap_admin_users not passed through verbatim"
jq -e '.local_admin_users == "carol"' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "local_admin_users not passed through verbatim"
jq -e --arg v "GOCSPX-test-secret-value-123456789" '.google_client_secret == $v' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "google_client_secret missing/wrong in generated tfvars"
jq -e '.ldap_search_rules == ["(uid=%u)|ou=users,dc=example,dc=com"]' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "ldap_search_rules is not the expected JSON list"
ok "a multi-source run names every source's variable"

# --- No admin grant leaves the installer as a server flag --------------------
jq -e 'has("additional_extra_args") | not' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "additional_extra_args key present in generated tfvars"
jq -e '[.. | strings | select(startswith("--admin-user"))] | length == 0' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "a value starting with --admin-user leaked into the generated tfvars"
ok "no admin grant leaves the installer as a server flag"

# --- The deprecated inputs cannot reach the module ---------------------------
jq -e 'has("auth_method") | not' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "auth_method key present in generated tfvars"

( export_common_vars; export AUTH_METHOD="ldap"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  MSG="$(collect_auth_inputs 2>&1 </dev/null)" && fail "collect_auth_inputs accepted AUTH_METHOD"
  printf '%s' "${MSG}" | grep -qi "sso_provider" || fail "AUTH_METHOD refusal does not name sso_provider: ${MSG}"
) || fail "the AUTH_METHOD refusal case did not exit 0"

( export_common_vars; export ADMIN_USERS="alice@example.com"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  MSG="$(collect_auth_inputs 2>&1 </dev/null)" && fail "collect_auth_inputs accepted ADMIN_USERS"
  printf '%s' "${MSG}" | grep -qi "sso_admin_users" || fail "ADMIN_USERS refusal does not name sso_admin_users: ${MSG}"
) || fail "the ADMIN_USERS refusal case did not exit 0"
ok "the deprecated inputs cannot reach the module"

# --- A boolean spelling other than the literal 'true' still gates local users
( export_common_vars
  export ENABLE_LOCAL_USERS="1"
  export SSO_PROVIDER="none"
  export LDAP_SERVER=""
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  MSG="$(collect_auth_inputs 2>&1 </dev/null)" && fail "collect_auth_inputs accepted ENABLE_LOCAL_USERS=1 with no htpasswd content"
  printf '%s' "${MSG}" | grep -qi "HTPASSWD_CONTENT" || fail "ENABLE_LOCAL_USERS=1 refusal does not name HTPASSWD_CONTENT: ${MSG}"
) || fail "the ENABLE_LOCAL_USERS=1 refusal case did not exit 0"
ok "ENABLE_LOCAL_USERS=1 with no htpasswd content is refused"

# --- An admin list reaches the tfvars with its source off -------------------
( export_common_vars
  export SSO_PROVIDER="none"
  export LDAP_SERVER=""
  export ENABLE_LOCAL_USERS="false"
  export SSO_ADMIN_USERS="alice@example.com"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  MSG="$(collect_auth_inputs 2>&1 </dev/null)" && fail "collect_auth_inputs accepted SSO_ADMIN_USERS with sso_provider=none"
  printf '%s' "${MSG}" | grep -qi "sso_provider" || fail "SSO_ADMIN_USERS refusal does not name sso_provider: ${MSG}"
) || fail "the orphaned SSO_ADMIN_USERS refusal case did not exit 0"
ok "an admin list with its source off is refused"

# --- An SSO slot other than google ships no client secret --------------------
ENTRA_TFVARS="${TMP}/entra.auto.tfvars.json"
(
  export_common_vars
  export SSO_PROVIDER="entra"
  export ENTRA_TENANT_ID="tenant-1"
  export ENTRA_CLIENT_ID="client-1"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  build_tfvars_json_platforma "${ENTRA_TFVARS}"
) || fail "the entra run did not exit 0"
jq -e '.entra_tenant_id == "tenant-1" and .entra_client_id == "client-1"' "${ENTRA_TFVARS}" >/dev/null \
  || fail "entra_tenant_id/entra_client_id missing/wrong in generated tfvars"
jq -e '[keys[] | select(endswith("client_secret"))] | length == 0' "${ENTRA_TFVARS}" >/dev/null \
  || fail "entra tfvars carry a client_secret key"

OIDC_TFVARS="${TMP}/oidc.auto.tfvars.json"
(
  export_common_vars
  export SSO_PROVIDER="oidc"
  export OIDC_ISSUER="https://idp.example.com"
  export OIDC_CLIENT_ID="client-1"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  build_tfvars_json_platforma "${OIDC_TFVARS}"
) || fail "the oidc run did not exit 0"
jq -e '.oidc_issuer == "https://idp.example.com"' "${OIDC_TFVARS}" >/dev/null \
  || fail "oidc_issuer missing/wrong in generated tfvars"
jq -e '[keys[] | select(endswith("client_secret"))] | length == 0' "${OIDC_TFVARS}" >/dev/null \
  || fail "oidc tfvars carry a client_secret key"
ok "an SSO slot other than google ships no client secret"

# --- An htpasswd file ships only with the source that advertises it ---------
DISABLED_LOCAL_TFVARS="${TMP}/disabled-local.auto.tfvars.json"
(
  export_common_vars
  export ENABLE_LOCAL_USERS="false"
  export HTPASSWD_CONTENT="alice:\$2y\$05\$abc"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  build_tfvars_json_platforma "${DISABLED_LOCAL_TFVARS}"
) || fail "the disabled-local run did not exit 0"
jq -e '.enable_local_users == false' "${DISABLED_LOCAL_TFVARS}" >/dev/null \
  || fail "enable_local_users != false in generated tfvars"
jq -e 'has("htpasswd_content") | not' "${DISABLED_LOCAL_TFVARS}" >/dev/null \
  || fail "htpasswd_content present although enable_local_users is false"

jq -e '.enable_local_users == true' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "enable_local_users != true in the multi-source tfvars"
jq -e 'has("htpasswd_content")' "${MULTI_SOURCE_TFVARS}" >/dev/null \
  || fail "htpasswd_content missing although enable_local_users is true"
ok "an htpasswd file ships only with the source that advertises it"

# --- A run with no source configured still produces a valid document --------
NO_SOURCE_TFVARS="${TMP}/no-source.auto.tfvars.json"
(
  export_common_vars
  export SSO_PROVIDER="none"
  export LDAP_SERVER=""
  export ENABLE_LOCAL_USERS="false"
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  build_tfvars_json_platforma "${NO_SOURCE_TFVARS}"
) || fail "the no-source run did not exit 0"
jq -e '.sso_provider == "none" and .enable_local_users == false
       and .sso_admin_users == "" and .ldap_admin_users == "" and .local_admin_users == ""' \
  "${NO_SOURCE_TFVARS}" >/dev/null \
  || fail "no-source run does not produce the expected always-present keys"
jq -e '(has("ldap_server") | not) and (has("htpasswd_content") | not)
       and (has("google_client_id") | not) and (has("entra_tenant_id") | not) and (has("oidc_issuer") | not)' \
  "${NO_SOURCE_TFVARS}" >/dev/null \
  || fail "no-source run carries a conditional auth key it should not"
ok "a run with no source configured still produces a valid document"

# --- The prompt path leaves every source key readable ------------------------
PROMPT_PATH_TFVARS="${TMP}/prompt-path.auto.tfvars.json"
(
  export_common_vars
  unset SSO_PROVIDER LDAP_SERVER ENABLE_LOCAL_USERS SSO_ADMIN_USERS LDAP_ADMIN_USERS LOCAL_ADMIN_USERS \
        HTPASSWD_CONTENT HTPASSWD_FILE AUTH_METHOD ADMIN_USERS
  # shellcheck source=/dev/null
  source "${INSTALL_SH}"
  printf '\n\n\n' | collect_auth_inputs
  build_tfvars_json_platforma "${PROMPT_PATH_TFVARS}"
) || fail "the prompt path did not exit 0"
jq -e '.sso_provider == "none" and .enable_local_users == false
       and .sso_admin_users == "" and .ldap_admin_users == "" and .local_admin_users == ""' \
  "${PROMPT_PATH_TFVARS}" >/dev/null \
  || fail "the prompt path did not leave every source key readable"
ok "the prompt path leaves every source key readable"

ok "Part A passed (generator side)"

# --- Part B: terraform consumes it ------------------------------------------
TF_BIN="$(command -v tofu || command -v terraform || true)"
if [[ -z "${TF_BIN}" ]]; then
  printf '\033[33m! skipping terraform validate — no tofu/terraform on PATH\033[0m\n'
  exit 0
fi

# Run in a temp copy so tofu init/validate never touches the tracked module
# (init would otherwise rewrite .terraform.lock.hcl on every run).
WORK="${TMP}/tf"
mkdir -p "${WORK}/tests"
cp "${TF_DIR}"/*.tf "${WORK}/"
cp "${TF_DIR}"/tests/*.tftest.hcl "${WORK}/tests/"
cp "${MULTI_SOURCE_TFVARS}" "${WORK}/zz-test.auto.tfvars.json"

( cd "${WORK}" && "${TF_BIN}" init -backend=false -input=false >/dev/null ) \
  || fail "terraform init failed"

# validate: module accepts install.sh's tfvars shape
( cd "${WORK}" && "${TF_BIN}" validate ) \
  || fail "terraform validate failed on install.sh-generated tfvars"
ok "terraform-platforma validates with install.sh's tfvars"

# test: value-flow — the generated tfvars wire through the module's tests
( cd "${WORK}" && "${TF_BIN}" test ) \
  || fail "tofu test failed — install.sh's tfvars did not wire through"
ok "tofu test: install.sh's tfvars wire through the module"

# --- Part C: each refusal names the line to write ---------------------------
# Each precondition in helm_release.platforma's lifecycle block must name the
# variable to set, not just fail. `tofu test` on a run block with no
# expect_failures prints the precondition's full error_message; a run block
# WITH expect_failures only names the failing resource and proves nothing
# about the text.
PART_C_WORK="${TMP}/tfc"
mkdir -p "${PART_C_WORK}/tests"
cp "${TF_DIR}"/*.tf "${PART_C_WORK}/"
cat >"${PART_C_WORK}/zz.auto.tfvars.json" <<'EOF'
{
  "project_id": "test-project",
  "master_secret_secret_id": "projects/test/secrets/master/versions/1",
  "gcs_bucket": "test-bucket",
  "filestore_instance_name": "test-fs",
  "license_key": "TEST-LICENSE"
}
EOF

# The mock_provider/override_data/variables header auth_migration.tftest.hcl
# needs to plan without cloud credentials, shared verbatim so a probe run
# block hits the same mocks the real refusal tests run under.
awk '/^run "/{exit} {print}' "${TF_DIR}/tests/auth_migration.tftest.hcl" \
  >"${PART_C_WORK}/tests/zz_header.tftest.hcl"

( cd "${PART_C_WORK}" && "${TF_BIN}" init -backend=false -input=false >/dev/null ) \
  || fail "terraform init failed for the precondition-message probe"

assert_precondition_message() {
  local case_name="$1" run_block="$2" expect_substring="$3"
  local probe="${PART_C_WORK}/tests/zz_probe.tftest.hcl"
  cat "${PART_C_WORK}/tests/zz_header.tftest.hcl" "${run_block}" >"${probe}"
  local output
  output="$(cd "${PART_C_WORK}" && "${TF_BIN}" test 2>&1)"
  local status=$?
  rm -f "${probe}"
  [[ ${status} -ne 0 ]] || fail "${case_name}: precondition did not fail"
  grep -qF "${expect_substring}" <<<"${output}" \
    || fail "${case_name}: message does not name \"${expect_substring}\": ${output}"
}

RUN_BLOCK="${TMP}/zz_run.tftest.hcl"

cat >"${RUN_BLOCK}" <<'EOF'
run "deprecated_selector" {
  command = plan
  variables {
    auth_method          = "ldap"
    google_client_id     = "id-1"
    google_client_secret = "secret-1"
    sso_provider         = "google"
    ldap_server          = ""
    enable_local_users   = false
    htpasswd_content     = ""
    sso_admin_users      = ""
    ldap_admin_users     = ""
    local_admin_users    = ""
  }
}
EOF
assert_precondition_message "deprecated selector" "${RUN_BLOCK}" \
  "ldap_server already switches the source on"

cat >"${RUN_BLOCK}" <<'EOF'
run "leftover_admin_flag" {
  command = plan
  variables {
    auth_method           = ""
    sso_provider          = "none"
    ldap_server           = ""
    enable_local_users    = false
    htpasswd_content      = ""
    sso_admin_users       = ""
    ldap_admin_users      = ""
    local_admin_users     = ""
    additional_extra_args = ["--admin-user=alice"]
  }
}
EOF
assert_precondition_message "leftover admin flag" "${RUN_BLOCK}" \
  "sso_admin_users"

cat >"${RUN_BLOCK}" <<'EOF'
run "local_users_no_file" {
  command = plan
  variables {
    auth_method          = ""
    sso_provider         = "none"
    ldap_server          = ""
    enable_local_users   = true
    htpasswd_content     = ""
    sso_admin_users      = ""
    ldap_admin_users     = ""
    local_admin_users    = ""
  }
}
EOF
assert_precondition_message "local users with no file" "${RUN_BLOCK}" \
  "htpasswd_content"

cat >"${RUN_BLOCK}" <<'EOF'
run "orphan_htpasswd" {
  command = plan
  variables {
    auth_method          = ""
    sso_provider         = "none"
    ldap_server          = ""
    enable_local_users   = false
    htpasswd_content     = "alice:$2y$05$abc"
    sso_admin_users      = ""
    ldap_admin_users     = ""
    local_admin_users    = ""
  }
}
EOF
assert_precondition_message "orphan htpasswd" "${RUN_BLOCK}" \
  "enable_local_users = true"

cat >"${RUN_BLOCK}" <<'EOF'
run "orphan_admin_grant" {
  command = plan
  variables {
    auth_method          = ""
    sso_provider         = "none"
    ldap_server          = ""
    enable_local_users   = false
    htpasswd_content     = ""
    sso_admin_users      = ""
    ldap_admin_users     = "svc-admin"
    local_admin_users    = ""
  }
}
EOF
assert_precondition_message "orphan admin grant" "${RUN_BLOCK}" \
  "ldap_server"

ok "each refusal names the line to write"

ok "combined install.sh ↔ terraform check passed"
