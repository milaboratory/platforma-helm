#!/usr/bin/env bash
# =============================================================================
# migration-tf.sh — split a PLAIN-TERRAFORM monolith deployment into the
#                   terraform-infra + terraform-platforma pair
# =============================================================================
# For deployments the operator applies themselves (GCS backend, Terraform
# Cloud, local state) — NOT Infrastructure Manager. For an IM deployment use
# the sibling ./migration.sh instead.
#
#   ./migration-tf.sh classify <state-file>   # completeness gate: every address is known
#   ./migration-tf.sh generate <state-file>   # print the `terraform state mv/rm` commands
#
# Both commands are READ-ONLY. They read a state dump you took yourself and
# print to stdout. Nothing touches the cloud, the live state, or your working
# directory. You run every mutating command by hand.
#
# THE PROCEDURE
# -------------
# 0. FREEZE. Pause any CI job or scheduled apply against this root module. Two
#    states fighting over the same resources is the one unrecoverable mistake.
#
# 1. DUMP THE STATE. This file is your only rollback — keep it.
#
#      terraform state pull > golden-monolith.tfstate
#      chmod 0400 golden-monolith.tfstate
#
# 2. CLASSIFY. Asserts every managed address of the monolith module lands in
#    exactly one partition list. Aborts and names anything it does not know.
#
#      ./migration-tf.sh classify golden-monolith.tfstate
#
#    If it names a resource: decide which half owns it and add it to the right
#    list in this script. Do NOT silence the failure by widening DROP or
#    RETIRE — those two have exact, documented memberships.
#
# 3. REWRITE THE ROOT MODULE. Replace the single monolith module call with two
#    calls, keeping every input value byte-identical to what the monolith gets
#    today. Wire the infra outputs in so Terraform has a real dependency edge
#    (you cannot use depends_on here — both modules declare provider blocks,
#    which Terraform rejects in combination with depends_on):
#
#      module "platforma_infra" {
#        source = "git::https://github.com/milaboratory/platforma-helm.git//infrastructure/gcp/terraform-infra?ref=7e89bb23479ca92daa7f15ac77eb25f5c8437d2e"
#        # project_id, region, zone_suffix, cluster_name, deployment_size,
#        # contact_email, ingress_*, dns_*, data_libraries, ...
#      }
#
#      module "platforma_platforma" {
#        source = "git::https://github.com/milaboratory/platforma-helm.git//infrastructure/gcp/terraform-platforma?ref=7e89bb23479ca92daa7f15ac77eb25f5c8437d2e"
#
#        gcs_bucket              = module.platforma_infra.gcs_bucket
#        filestore_instance_name = module.platforma_infra.filestore_instance_name
#
#        # The monolith OWNED the master secret; the split reads it by name.
#        # The monolith named it "${var.cluster_name}-platforma-master-secret".
#        # Confirm against your state before trusting this:
#        #   jq -r '.resources[]|select(.type=="google_secret_manager_secret")
#        #          |.instances[0].attributes.secret_id' golden-monolith.tfstate
#        master_secret_secret_id = "${var.cluster_name}-platforma-master-secret"
#
#        # license_key, auth_method, htpasswd_content, deployment_size, ...
#      }
#
#      terraform init
#
# 4. GENERATE the state commands and review them:
#
#      ./migration-tf.sh generate golden-monolith.tfstate > state-moves.sh
#
# 5. MUTATE THE STATE. Prefer operating on a working copy and pushing once —
#    one remote write, one lock, and golden-monolith.tfstate stays clean:
#
#      terraform state pull > working.tfstate
#      ./migration-tf.sh generate golden-monolith.tfstate \
#        --working-state working.tfstate > state-moves.sh
#      bash -x state-moves.sh
#      terraform state push working.tfstate
#
#    Running the commands without --working-state is also fine; it is just one
#    remote state write per command.
#
# 6. PLAN — this is the gate. Nothing has changed in the cloud yet.
#
#      terraform plan -out=tfplan
#
#    It must show:
#      * NO deletes and NO replaces. A node pool, cluster or Filestore replace
#        means an immutable field differs between the live resource and your
#        new module inputs. Reconcile the INPUTS, never the state. The usual
#        culprits are system_pool_node_count (monolith default 2, split
#        default 1) and zone_suffix.
#      * Creates ONLY for the resources the split adds that the monolith never
#        had — `generate` prints that list for you.
#      * Nothing at all touching google_secret_manager_secret.master_secret.
#
# 7. APPLY.
#
#      terraform apply tfplan
#
# 8. VERIFY, in this order:
#      * A project that existed BEFORE the migration still opens. This is the
#        master-secret check and the only one that matters for data.
#      * The UI answers on the EXISTING ingress IP with the EXISTING cert.
#      * No second cluster, bucket or Filestore instance was created.
#      * Batch jobs still schedule: kubectl get nodes -L cloud.google.com/compute-class
#
# ROLLBACK: until step 7 you have changed nothing in the cloud. Push
# golden-monolith.tfstate back and carry on with the monolith module.
#
# THE ONE GENUINELY DANGEROUS ITEM
# --------------------------------
# The monolith owns random_id.master_secret -> the Secret Manager secret ->
# its version. The split has no such resource; it reads the value through
# var.master_secret_secret_id. Those three are therefore REMOVED from
# Terraform management (`state rm`) while the Secret Manager object itself is
# left in place. The master secret is the encryption key for the deployment's
# artefacts: destroy and recreate it and every existing project becomes
# unreadable, with no infrastructure backup that can bring it back. Never let
# the DROP list be "fixed" into a move, and never approve a plan that touches
# that secret.
#
# Options:
#   --source-module ADDR    module holding the monolith (default: auto-detected
#                           from google_container_cluster.primary; pass '' if
#                           the monolith sits at the root)
#   --infra-module ADDR     move target for the infra half
#                           (default: module.platforma_infra)
#   --platforma-module ADDR move target for the platforma half
#                           (default: module.platforma_platforma)
#   --working-state FILE    emit `-state=FILE` on every generated command
#   -h, --help              this guide
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_MODULE=""          # auto-detected unless --source-module is given
SOURCE_MODULE_SET=false
INFRA_MODULE="module.platforma_infra"
PLATFORMA_MODULE="module.platforma_platforma"
WORKING_STATE=""

# -----------------------------------------------------------------------------
# The partition
# -----------------------------------------------------------------------------
# Kept identical to the lists in ./migration.sh — the IM and plain-Terraform
# paths split the SAME module the same way. Update both together; `classify`
# warns if they have drifted.

# -- terraform-infra/ owns these.
KEEP_INFRA=(
  google_project_service.enabled
  google_compute_network.vpc
  google_compute_subnetwork.nodes
  google_compute_router.primary
  google_compute_router_nat.primary
  google_compute_global_address.private_service_access
  google_compute_global_address.ingress
  google_service_networking_connection.psa
  google_container_cluster.primary
  google_container_node_pool.system
  google_container_node_pool.ui
  google_filestore_instance.workspace
  google_storage_bucket.primary
  random_id.bucket_suffix
  google_storage_bucket_iam_member.server_bucket_admin
  google_storage_bucket_iam_member.jobs_bucket_admin
  google_storage_bucket_iam_member.data_library_server_objectviewer
  google_storage_bucket_iam_member.data_library_jobs_objectviewer
  google_service_account.server
  google_service_account.jobs
  google_service_account_iam_member.server_wi
  google_service_account_iam_member.jobs_wi
  google_service_account_iam_member.server_token_creator_self
  google_service_account_iam_member.jobs_token_creator_self
  google_certificate_manager_dns_authorization.platforma
  google_certificate_manager_certificate.platforma
  google_certificate_manager_certificate_map.platforma
  google_certificate_manager_certificate_map_entry.platforma
  google_dns_record_set.cert_validation
  google_dns_record_set.platforma
  google_cloud_quotas_quota_preference.platforma
)

# -- terraform-platforma/ owns these.
#    State-only resources (null_resource, terraform_data) move like any other
#    entry here — unlike the IM path, they are not recreated.
KEEP_PLATFORMA=(
  kubernetes_namespace.platforma
  helm_release.kueue
  helm_release.platforma
  terraform_data.appwrapper_manifest_integrity
  kubectl_manifest.appwrapper
  kubectl_manifest.batch_compute_class
  kubectl_manifest.platforma_gateway
  kubectl_manifest.platforma_route
  kubectl_manifest.platforma_healthcheck
  kubernetes_secret.master_secret
  kubernetes_secret.license
  kubernetes_secret.data_library
  kubernetes_secret.htpasswd_provided
  kubernetes_secret.ldap_search_password
  random_password.admin
  google_secret_manager_secret.admin_password
  google_secret_manager_secret_version.admin_password
  null_resource.wait_gateway_gfe_cleanup
)

# -- Dropped from BOTH halves. The cloud objects are NOT destroyed; they simply
#    stop being Terraform-managed. terraform-platforma reads the master secret
#    through data.google_secret_manager_secret_version instead of owning it.
DROP=(
  random_id.master_secret
  google_secret_manager_secret.master_secret
  google_secret_manager_secret_version.master_secret
)

# -- Dropped from both halves AND scheduled for manual deletion afterwards.
#    Static batch node pools predating the batch ComputeClass migration. Absent
#    from a recently-migrated monolith (classify reports them listed-but-absent,
#    which is expected).
RETIRE=(
  google_container_node_pool.batch
)

# -- Resources the split modules add that the monolith never had. They appear
#    in `terraform plan` as CREATEs — an intended monolith→split difference,
#    NOT a failed move. Anything creating outside this list needs explaining.
KNOWN_NEW=(
  google_artifact_registry_repository.pl_containers
  google_artifact_registry_repository_iam_member.pl_containers_server_reader
  google_artifact_registry_repository_iam_member.pl_containers_jobs_reader
  'google_project_service.enabled["artifactregistry.googleapis.com"]'
)

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; N=$'\033[0m'
else
  B=""; R=""; Y=""; G=""; N=""
fi
# Diagnostics go to stderr so `generate > state-moves.sh` stays clean.
bold() { echo "${B}$*${N}" >&2; }
info() { echo "  $*" >&2; }
ok()   { echo "${G}  ✓ $*${N}" >&2; }
warn() { echo "${Y}  ! $*${N}" >&2; }
die()  { echo "${R}  ✗ $*${N}" >&2; exit 1; }

usage() {
  awk 'NR==1 {next} !/^#/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
}

# -----------------------------------------------------------------------------
# State readers
# -----------------------------------------------------------------------------
require_state() {
  [[ -n "${STATE_FILE:-}" ]] || die "give a state file: ./migration-tf.sh $1 <state-file>"
  [[ -f "${STATE_FILE}" ]]   || die "no such file: ${STATE_FILE}"
  command -v jq >/dev/null   || die "'jq' not found on PATH"
  jq -e '.version and (.resources | type == "array")' "${STATE_FILE}" >/dev/null 2>&1 \
    || die "${STATE_FILE} is not a Terraform state dump (expected .version and .resources)"
}

# The module address holding the monolith. Auto-detected from the cluster,
# which every monolith has exactly one of.
detect_source_module() {
  # A root-module resource has no .module key at all, so the empty string is a
  # legitimate answer here — it cannot double as "not found". Tag the root with
  # a sentinel and strip it back off.
  local found n
  found="$(jq -r '.resources[]
                  | select(.mode=="managed" and .type=="google_container_cluster" and .name=="primary")
                  | (.module // "<root>")' "${STATE_FILE}" | sort -u)"
  n="$(echo "${found}" | grep -c . || true)"
  if [[ "${n}" == "0" ]]; then
    die "no google_container_cluster.primary in ${STATE_FILE} — is this the right state? Pass --source-module to override."
  elif [[ "${n}" != "1" ]]; then
    die "found google_container_cluster.primary in several modules; pass --source-module explicitly:
$(echo "${found}" | sed 's/^/        /')"
  fi
  [[ "${found}" == "<root>" ]] && found=""
  SOURCE_MODULE="${found}"
}

SOURCE_MODULE_RESOLVED=false
resolve_source_module() {
  [[ "${SOURCE_MODULE_RESOLVED}" == "true" ]] && return 0
  if [[ "${SOURCE_MODULE_SET}" == "false" ]]; then
    detect_source_module
    info "source module (auto-detected): ${SOURCE_MODULE:-<root>}"
  else
    info "source module: ${SOURCE_MODULE:-<root>}"
  fi
  SOURCE_MODULE_RESOLVED=true
}

# Base addresses ("type.name") of managed resources inside the source module.
scoped_addresses() {
  jq -r --arg m "${SOURCE_MODULE}" '
    .resources[]
    | select(.mode=="managed")
    | select((.module // "") == $m)
    | "\(.type).\(.name)"' "${STATE_FILE}" | sort -u
}

# Everything else in the state — left completely untouched by this migration.
out_of_scope_modules() {
  jq -r --arg m "${SOURCE_MODULE}" '
    .resources[]
    | select(.mode=="managed")
    | select((.module // "") != $m)
    | (.module // "<root>")' "${STATE_FILE}" | sort | uniq -c | sort -rn
}

addrs_to_json() { printf '%s\n' "$@" | jq -R . | jq -s .; }

# Warn if the partition has drifted from the IM script's copy.
check_list_drift() {
  local sibling="${SCRIPT_DIR}/migration.sh"
  [[ -f "${sibling}" ]] || return 0
  local theirs mine list
  for list in KEEP_INFRA KEEP_PLATFORMA DROP RETIRE; do
    theirs="$(sed -n "/^${list}=(/,/^)/p" "${sibling}" | grep -E '^  [a-z]' | tr -d ' ' | sort -u)"
    [[ -n "${theirs}" ]] || continue
    case "${list}" in
      KEEP_INFRA)     mine="$(printf '%s\n' "${KEEP_INFRA[@]}" | sort -u)" ;;
      KEEP_PLATFORMA) mine="$(printf '%s\n' "${KEEP_PLATFORMA[@]}" | sort -u)" ;;
      DROP)           mine="$(printf '%s\n' "${DROP[@]}" | sort -u)" ;;
      RETIRE)         mine="$(printf '%s\n' "${RETIRE[@]}" | sort -u)" ;;
    esac
    if [[ "${theirs}" != "${mine}" ]]; then
      warn "${list} differs from migration.sh — the two migration paths must"
      warn "partition the module identically. Reconcile before continuing:"
      diff <(echo "${mine}") <(echo "${theirs}") | sed 's/^/        /' >&2 || true
    fi
  done
}

# -----------------------------------------------------------------------------
# classify — the completeness gate
# -----------------------------------------------------------------------------
cmd_classify() {
  require_state classify
  bold "Classifying monolith resources in ${STATE_FILE}"
  resolve_source_module
  check_list_drift

  local all known unclassified missing oos
  all="$(scoped_addresses)"
  known="$(printf '%s\n' "${KEEP_INFRA[@]}" "${KEEP_PLATFORMA[@]}" "${DROP[@]}" "${RETIRE[@]}" | sort -u)"

  unclassified="$(comm -23 <(echo "${all}") <(echo "${known}"))"
  missing="$(comm -13 <(echo "${all}") <(echo "${known}"))"

  info "in scope:                     $(echo "${all}" | grep -c . || true)"
  info "→ ${INFRA_MODULE}: ${#KEEP_INFRA[@]}"
  info "→ ${PLATFORMA_MODULE}: ${#KEEP_PLATFORMA[@]}"
  info "→ dropped (kept in GCP):      ${#DROP[@]}"
  info "→ unmanaged, retire by hand:  ${#RETIRE[@]}"

  oos="$(out_of_scope_modules)"
  if [[ -n "${oos}" ]]; then
    info ""
    info "outside ${SOURCE_MODULE:-<root>} — not touched by this migration:"
    echo "${oos}" | sed 's/^/      /' >&2
  fi

  if [[ -n "${unclassified}" ]]; then
    warn "these addresses exist in the state but are in NO list:"
    echo "${unclassified}" | sed 's/^/      /' >&2
    die "refusing to proceed — classify every address above, then re-run"
  fi
  ok "every in-scope address is classified"

  if [[ -n "${missing}" ]]; then
    warn "these addresses are listed but absent from the state. Expected for"
    warn "count/for_each-gated resources and for RETIRE on a recent monolith."
    warn "Anything else is suspicious:"
    echo "${missing}" | sed 's/^/      /' >&2
  fi

  bold "Dropped from Terraform management (cloud objects preserved):"
  printf '      %s\n' "${DROP[@]}" >&2
  warn "google_secret_manager_secret.master_secret is the deployment's"
  warn "encryption key. It must be DROPPED, never moved, and never recreated."
}

# -----------------------------------------------------------------------------
# generate — emit the state commands (to stdout; nothing is executed)
# -----------------------------------------------------------------------------

# emit_moves <target-module> <base-address>...
# One command per resource BLOCK: `terraform state mv` carries every instance
# of a count/for_each resource, so no index handling is needed here.
emit_moves() {
  local dst="$1"; shift
  local keep_json; keep_json="$(addrs_to_json "$@")"
  jq -r --arg m "${SOURCE_MODULE}" --arg dst "${dst}" --arg sf "${STATE_FLAG}" --argjson keep "${keep_json}" '
    [ .resources[]
      | select(.mode=="managed")
      | select((.module // "") == $m)
      | select("\(.type).\(.name)" as $b | ($keep | index($b)))
      | (if $m == "" then "" else $m + "." end) as $src
      | "terraform state mv \($sf)'\''\($src)\(.type).\(.name)'\'' '\''\($dst).\(.type).\(.name)'\''"
    ] | sort | .[]' "${STATE_FILE}"
}

# emit_removals <base-address>...
emit_removals() {
  local drop_json; drop_json="$(addrs_to_json "$@")"
  jq -r --arg m "${SOURCE_MODULE}" --arg sf "${STATE_FLAG}" --argjson drop "${drop_json}" '
    [ .resources[]
      | select(.mode=="managed")
      | select((.module // "") == $m)
      | select("\(.type).\(.name)" as $b | ($drop | index($b)))
      | (if $m == "" then "" else $m + "." end) as $src
      | "terraform state rm \($sf)'\''\($src)\(.type).\(.name)'\''"
    ] | sort | .[]' "${STATE_FILE}"
}

cmd_generate() {
  require_state generate

  # The completeness gate runs first: never emit commands for a partition that
  # does not account for every resource. classify reports on stderr and calls
  # die() — which exits — if anything is unclassified, so its diagnosis reaches
  # the operator while stdout stays a clean command stream.
  cmd_classify >/dev/null
  echo >&2

  STATE_FLAG=""
  if [[ -n "${WORKING_STATE}" ]]; then
    STATE_FLAG="-state=${WORKING_STATE} "
  fi

  local infra_cmds platforma_cmds drop_cmds retire_cmds
  infra_cmds="$(emit_moves "${INFRA_MODULE}" "${KEEP_INFRA[@]}")"
  platforma_cmds="$(emit_moves "${PLATFORMA_MODULE}" "${KEEP_PLATFORMA[@]}")"
  drop_cmds="$(emit_removals "${DROP[@]}")"
  retire_cmds="$(emit_removals "${RETIRE[@]}")"

  cat <<EOF
#!/usr/bin/env bash
# Generated by migration-tf.sh from ${STATE_FILE}
#
# REVIEW BEFORE RUNNING. Every command edits Terraform state only — no cloud
# resource is created, changed or destroyed by anything in this file.
#
#   source module : ${SOURCE_MODULE:-<root>}
#   infra half    : ${INFRA_MODULE}
#   platforma half: ${PLATFORMA_MODULE}
EOF
  if [[ -n "${WORKING_STATE}" ]]; then
    cat <<EOF
#   working state : ${WORKING_STATE}  (push it when the run completes:
#                   terraform state push ${WORKING_STATE})
EOF
  else
    cat <<'EOF'
#   working state : none — each command performs its own remote state write.
#                   Consider --working-state to batch them into one push.
EOF
  fi
  cat <<'EOF'
#
# Run `terraform plan` afterwards. It is the gate: no deletes, no replaces,
# and creates only for the resources listed at the end of this file.
set -euo pipefail

EOF

  echo "# --- infra half: $(echo "${infra_cmds}" | grep -c . || true) resources ---"
  echo "${infra_cmds}"
  echo
  echo "# --- platforma half: $(echo "${platforma_cmds}" | grep -c . || true) resources ---"
  echo "${platforma_cmds}"
  echo

  cat <<'EOF'
# --- drop from Terraform management (the cloud objects SURVIVE) ---
# The master secret is the deployment's encryption key. It leaves Terraform
# management here and is read back by name through
# var.master_secret_secret_id. If any of the three below is missing from this
# list, or appears as a move instead, STOP.
EOF
  if [[ -n "${drop_cmds}" ]]; then
    echo "${drop_cmds}"
  else
    echo "# (none present in this state)"
  fi
  echo

  echo "# --- static batch node pools: unmanage now, delete by hand later ---"
  if [[ -n "${retire_cmds}" ]]; then
    cat <<'EOF'
# These predate the batch ComputeClass. They keep running and keep serving
# jobs. Delete them only once the ComputeClass is demonstrably scheduling new
# batch work:
#   kubectl get nodes -L cloud.google.com/compute-class,role
#   gcloud container node-pools delete <pool> --cluster=<cluster> --location=<zone>
EOF
    echo "${retire_cmds}"
  else
    echo "# (none present — this monolith is already on the batch ComputeClass)"
  fi
  echo

  cat <<'EOF'
# --- expected CREATEs in the plan that follows ---
# The split adds resources the monolith never had. These are the only creates
# the plan should show; anything else means a resource failed to move.
EOF
  printf '#   %s\n' "${KNOWN_NEW[@]}"
  cat <<'EOF'
#
# Note: `terraform state mv` does not rewrite the `dependencies` arrays of
# other resources, so the state will briefly hold references to the old
# addresses. Terraform recomputes dependencies on the next apply — harmless.
EOF

  local n_i n_p
  n_i="$(echo "${infra_cmds}" | grep -c . || true)"
  n_p="$(echo "${platforma_cmds}" | grep -c . || true)"
  ok "emitted ${n_i} infra moves, ${n_p} platforma moves, $(echo "${drop_cmds}" | grep -c . || true) drops, $(echo "${retire_cmds}" | grep -c . || true) retires"
  info "review the output, then run it, then: terraform plan -out=tfplan"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
COMMAND=""
STATE_FILE=""
STATE_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)     usage; exit 0 ;;
    --source-module)    SOURCE_MODULE="${2:-}"; SOURCE_MODULE_SET=true; shift 2 ;;
    --infra-module)     INFRA_MODULE="${2:?--infra-module needs a value}"; shift 2 ;;
    --platforma-module) PLATFORMA_MODULE="${2:?--platforma-module needs a value}"; shift 2 ;;
    --working-state)    WORKING_STATE="${2:?--working-state needs a value}"; shift 2 ;;
    -*)                 die "unknown option: $1 (see --help)" ;;
    classify|generate)  COMMAND="$1"; shift ;;
    *)
      [[ -z "${STATE_FILE}" ]] || die "unexpected argument: $1"
      STATE_FILE="$1"; shift ;;
  esac
done

case "${COMMAND}" in
  classify) cmd_classify ;;
  generate) cmd_generate ;;
  *)        usage; exit 1 ;;
esac
