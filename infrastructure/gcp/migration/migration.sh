#!/usr/bin/env bash
# =============================================================================
# migration.sh — split a monolithic GCP Platforma deployment into the
#                terraform-infra + terraform-platforma pair
# =============================================================================
# See ../migration.md for the full procedure, the rationale, and the rollback
# path. This script is the executable half of that document; run the phases in
# order and read the guide alongside it.
#
#   ./migration.sh preflight    # tooling, auth, deployment states
#   ./migration.sh export       # monolith state -> work dir (the safety copy)
#   ./migration.sh classify     # completeness check; prints the partition
#   ./migration.sh split        # produce infra.tfstate + platforma.tfstate
#   ./migration.sh seed         # create both empty target IM deployments
#   ./migration.sh import       # lock -> import-statefile -> unlock, both
#   ./migration.sh preview      # zero-destroy gate (run before apply!)
#   ./migration.sh retire       # AFTER apply: retire static batch pools, if any
#
# Everything up to and including `import` is reversible and touches no cloud
# resource: it reads one statefile and writes deployments that are empty.
# `preview` is read-only, and `retire` only prints commands. The real applies
# are driven by cloudshell/install.sh, NOT by this script — see migration.md
# Phase 5.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Validated lazily by require_config() so that running with no arguments still
# prints usage instead of dying on an unset variable.
PROJECT_ID="${PROJECT_ID:-}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-}"
IM_LOCATION="${IM_LOCATION:-europe-west1}"
IM_SA_EMAIL="${IM_SA_EMAIL:-platforma-im-deployer@${PROJECT_ID}.iam.gserviceaccount.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR_OVERRIDE="${WORK_DIR:-}"   # set WORK_DIR in the environment to relocate
SEED_DIR="${SCRIPT_DIR}/seed"
SPLIT_JQ="${SCRIPT_DIR}/split-state.jq"

# Real module bundles, used by `preview` only.
GCP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_TF_DIR="${GCP_DIR}/terraform-infra"
PLATFORMA_TF_DIR="${GCP_DIR}/terraform-platforma"

# -----------------------------------------------------------------------------
# The partition
# -----------------------------------------------------------------------------
# Base (index-free) addresses as they appear in the monolith state. Resources
# using count/for_each are listed once here; removing a base address removes
# all of its instances.
#
# These lists are NOT a convenience — `classify` asserts that every managed
# address in the exported state appears in exactly one of them, and aborts
# otherwise. If someone adds a resource to the monolith module later, this
# migration fails loudly at the classify step instead of silently orphaning it.
# When that happens, decide which half the new resource belongs to and add it
# to the right list; do not "fix" the failure by widening the drop list.

# -- Everything the infra module (terraform-infra/) owns.
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

# -- Everything the platforma module (terraform-platforma/) owns.
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

# -- Dropped from BOTH halves. The underlying cloud objects are NOT destroyed;
#    they simply stop being Terraform-managed.
#
#    The refactor converted the master secret from Terraform-owned to
#    bring-your-own: terraform-platforma/app.tf reads it through
#    data.google_secret_manager_secret_version, and its name arrives as
#    var.master_secret_secret_id. Leaving these three in either half would
#    hand a *data* source's target to a *managed* resource in the next apply
#    — and any plan that replaces the master secret destroys the ability to
#    read every artefact the deployment has ever encrypted.
DROP=(
  random_id.master_secret
  google_secret_manager_secret.master_secret
  google_secret_manager_secret_version.master_secret
)

# -- Dropped from both halves AND scheduled for manual deletion afterwards.
#    Present only in deployments that predate the batch ComputeClass migration
#    (monolith commits 9b586ca / 11c7e16). Those provisioned one static batch
#    node pool per machine shape; the split module has none — batch nodes are
#    created on demand by the `platforma-batch` ComputeClass that
#    terraform-platforma/computeclass.tf installs.
#
#    There is nothing in the new configuration for these to map onto, so they
#    leave Terraform management entirely. The nodes keep running and keep
#    serving jobs until the ComputeClass takes over; only then are they drained
#    and deleted by hand (`./migration.sh retire` prints the commands).
#
#    A deployment migrated from a recent monolith will not have these in state
#    at all — `classify` reports them as listed-but-absent, which is expected.
RETIRE=(
  google_container_node_pool.batch
)

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; N=$'\033[0m'
else
  B=""; R=""; Y=""; G=""; N=""
fi
bold() { echo "${B}$*${N}"; }
info() { echo "  $*"; }
ok()   { echo "${G}  ✓ $*${N}"; }
warn() { echo "${Y}  ! $*${N}" >&2; }
die()  { echo "${R}  ✗ $*${N}" >&2; exit 1; }

require_config() {
  [[ -n "${PROJECT_ID}" ]] \
    || die "set PROJECT_ID to the GCP project holding the monolith deployment"
  [[ -n "${DEPLOYMENT_NAME}" ]] \
    || die "set DEPLOYMENT_NAME to the existing monolith IM deployment name"

  # Derived from the two above, so they are resolved here rather than at load
  # time (when the variables may still be empty).
  INFRA_DEPLOYMENT="${DEPLOYMENT_NAME}-infra"
  PLATFORMA_DEPLOYMENT="${DEPLOYMENT_NAME}-platforma"
  WORK_DIR="${WORK_DIR_OVERRIDE:-${SCRIPT_DIR}/.work/${PROJECT_ID}-${DEPLOYMENT_NAME}}"
}

im() { gcloud infra-manager "$@" --project="${PROJECT_ID}" --location="${IM_LOCATION}"; }

deployment_state() {
  im deployments describe "$1" --format='value(state)' 2>/dev/null || echo NOTFOUND
}

# Base addresses of all managed resources in a state file, sorted and unique.
state_addresses() {
  jq -r '.resources[] | select(.mode=="managed") | "\(.type).\(.name)"' "$1" | sort -u
}

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
cmd_preflight() {
  bold "Preflight"

  for t in gcloud jq; do
    command -v "$t" >/dev/null || die "'$t' not found on PATH"
  done
  ok "gcloud and jq present"

  [[ -f "${SPLIT_JQ}" ]]        || die "missing ${SPLIT_JQ}"
  [[ -f "${SEED_DIR}/main.tf" ]] || die "missing ${SEED_DIR}/main.tf"
  ok "seed bundle and split program present"

  gcloud auth print-access-token >/dev/null 2>&1 \
    || die "not authenticated — run: gcloud auth login"
  ok "authenticated as $(gcloud config get-value account 2>/dev/null)"

  gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1 \
    || die "cannot read project ${PROJECT_ID}"
  ok "project ${PROJECT_ID} reachable"

  local src; src="$(deployment_state "${DEPLOYMENT_NAME}")"
  case "${src}" in
    ACTIVE) ok "monolith deployment ${DEPLOYMENT_NAME} is ACTIVE" ;;
    NOTFOUND) die "monolith deployment ${DEPLOYMENT_NAME} not found in ${IM_LOCATION}" ;;
    *) die "monolith deployment ${DEPLOYMENT_NAME} is ${src}; it must be ACTIVE before migrating" ;;
  esac

  # Targets must not already exist with real content — importing over a
  # deployment that already manages resources would orphan them.
  local d st
  for d in "${INFRA_DEPLOYMENT}" "${PLATFORMA_DEPLOYMENT}"; do
    st="$(deployment_state "${d}")"
    if [[ "${st}" == "NOTFOUND" ]]; then
      ok "target ${d} does not exist yet (expected)"
    else
      warn "target ${d} already exists (state: ${st})"
      warn "  if this is a re-run of a failed attempt, see 'Re-running after a failure' in migration.md"
    fi
  done

  gcloud iam service-accounts describe "${IM_SA_EMAIL}" --project="${PROJECT_ID}" >/dev/null 2>&1 \
    || die "IM deployer service account ${IM_SA_EMAIL} not found; set IM_SA_EMAIL"
  ok "IM deployer SA ${IM_SA_EMAIL}"

  mkdir -p "${WORK_DIR}"
  ok "work dir ${WORK_DIR}"
}

# -----------------------------------------------------------------------------
# export
# -----------------------------------------------------------------------------
cmd_export() {
  bold "Exporting monolith state"
  mkdir -p "${WORK_DIR}"

  local out="${WORK_DIR}/monolith.tfstate"
  if [[ -f "${out}" ]]; then
    warn "${out} already exists — keeping it (delete it by hand to re-export)"
  else
    im deployments export-statefile "${DEPLOYMENT_NAME}" --file="${out}"
    ok "exported to ${out}"
  fi

  # The golden copy. Every rehearsal reset re-imports THIS file; nothing in
  # this script ever writes to it again.
  local golden="${WORK_DIR}/golden-monolith.tfstate"
  [[ -f "${golden}" ]] || cp "${out}" "${golden}"
  chmod 0400 "${golden}"
  ok "golden snapshot ${golden} (read-only)"

  info "resources under management: $(state_addresses "${out}" | wc -l | tr -d ' ') distinct addresses"
}

# -----------------------------------------------------------------------------
# classify — the completeness gate
# -----------------------------------------------------------------------------
cmd_classify() {
  bold "Classifying monolith resources"
  local src="${WORK_DIR}/monolith.tfstate"
  [[ -f "${src}" ]] || die "no exported state — run './migration.sh export' first"

  local all known unclassified missing
  all="$(state_addresses "${src}")"
  known="$(printf '%s\n' "${KEEP_INFRA[@]}" "${KEEP_PLATFORMA[@]}" "${DROP[@]}" "${RETIRE[@]}" | sort -u)"

  unclassified="$(comm -23 <(echo "${all}") <(echo "${known}"))"
  missing="$(comm -13 <(echo "${all}") <(echo "${known}"))"

  info "in state:      $(echo "${all}"   | grep -c . || true)"
  info "→ terraform-infra:      ${#KEEP_INFRA[@]}"
  info "→ terraform-platforma:  ${#KEEP_PLATFORMA[@]}"
  info "→ dropped (kept in GCP): ${#DROP[@]}"
  info "→ unmanaged, retire by hand: ${#RETIRE[@]}"

  if [[ -n "${unclassified}" ]]; then
    warn "these addresses exist in the state but are in NO list:"
    echo "${unclassified}" | sed 's/^/      /' >&2
    die "refusing to split — classify every address above, then re-run"
  fi
  ok "every address in the state is classified"

  if [[ -n "${missing}" ]]; then
    warn "these addresses are listed but absent from the state. Expected for"
    warn "resources gated on count/for_each, and for the RETIRE list on any"
    warn "monolith already migrated to the batch ComputeClass. Anything else"
    warn "is suspicious:"
    echo "${missing}" | sed 's/^/      /' >&2
  fi

  bold "Dropped from Terraform management (cloud objects preserved):"
  printf '      %s\n' "${DROP[@]}"

  # Only meaningful when the source deployment actually has static batch pools.
  local retire_present=""
  local a
  for a in "${RETIRE[@]}"; do
    grep -qx "${a}" <<<"${all}" && retire_present+="${a}"$'\n'
  done
  if [[ -n "${retire_present}" ]]; then
    echo
    warn "This deployment predates the batch ComputeClass migration. These static"
    warn "batch node pools have no equivalent in the split module:"
    echo "${retire_present}" | grep . | sed 's/^/      /' >&2
    warn "They leave Terraform management with the split and must be drained and"
    warn "deleted by hand AFTER the ComputeClass is serving jobs."
    warn "  → run './migration.sh retire' after Phase 5; see migration.md Phase 5b."
  fi
}

# -----------------------------------------------------------------------------
# split
# -----------------------------------------------------------------------------
cmd_split() {
  cmd_classify
  bold "Splitting state"

  local src="${WORK_DIR}/monolith.tfstate"
  local half keep_json out

  for half in infra platforma; do
    if [[ "${half}" == "infra" ]]; then
      keep_json="$(printf '%s\n' "${KEEP_INFRA[@]}"     | jq -R . | jq -s .)"
    else
      keep_json="$(printf '%s\n' "${KEEP_PLATFORMA[@]}" | jq -R . | jq -s .)"
    fi
    out="${WORK_DIR}/${half}.tfstate"

    jq --argjson keep "${keep_json}" --argjson bump 1000 \
       -f "${SPLIT_JQ}" "${src}" > "${out}"

    ok "${out} — $(state_addresses "${out}" | wc -l | tr -d ' ') addresses, serial $(jq -r .serial "${out}")"
  done

  # Independent verification: the two halves plus the drop list must exactly
  # reconstitute the source. This catches a jq filter that silently matched
  # nothing far better than eyeballing the counts above.
  # DROP/RETIRE entries are only counted when the source state actually held
  # them — RETIRE in particular is absent from any recently-migrated monolith.
  local unmanaged recombined
  unmanaged="$(comm -12 \
    <(printf '%s\n' "${DROP[@]}" "${RETIRE[@]}" | sort -u) \
    <(state_addresses "${src}"))"
  recombined="$(cat \
    <(state_addresses "${WORK_DIR}/infra.tfstate") \
    <(state_addresses "${WORK_DIR}/platforma.tfstate") \
    <(echo "${unmanaged}") | grep . | sort -u)"
  if ! diff -q <(state_addresses "${src}") <(echo "${recombined}") >/dev/null; then
    diff <(state_addresses "${src}") <(echo "${recombined}") | sed 's/^/      /' >&2
    die "split is not a clean partition of the source state (diff above)"
  fi
  ok "split verified: infra ∪ platforma ∪ dropped == monolith, no overlap"
}

# -----------------------------------------------------------------------------
# seed
# -----------------------------------------------------------------------------
seed_one() {
  local dep="$1"
  local st; st="$(deployment_state "${dep}")"
  if [[ "${st}" != "NOTFOUND" ]]; then
    warn "${dep} already exists (${st}) — skipping seed"
    return 0
  fi
  info "creating empty deployment ${dep}…"
  im deployments apply "${dep}" \
    --local-source="${SEED_DIR}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --quiet
  st="$(deployment_state "${dep}")"
  [[ "${st}" == "ACTIVE" ]] || die "${dep} settled in state ${st}, expected ACTIVE"
  ok "${dep} ACTIVE with an empty state"
}

cmd_seed() {
  bold "Seeding target deployments"
  seed_one "${INFRA_DEPLOYMENT}"
  seed_one "${PLATFORMA_DEPLOYMENT}"
}

# -----------------------------------------------------------------------------
# import
# -----------------------------------------------------------------------------
import_one() {
  local dep="$1" file="$2"
  [[ -f "${file}" ]] || die "missing ${file} — run './migration.sh split' first"

  local st; st="$(deployment_state "${dep}")"
  [[ "${st}" == "ACTIVE" ]] || die "${dep} is ${st}; it must be ACTIVE to import"

  info "locking ${dep}…"
  im deployments lock "${dep}" >/dev/null
  local lock_id
  lock_id="$(im deployments describe "${dep}" --format='value(lockState.lockId)' 2>/dev/null || true)"
  if [[ -z "${lock_id}" ]]; then
    # Field name varies across gcloud releases; fall back to a full describe.
    lock_id="$(im deployments describe "${dep}" --format=json | jq -r '.. | .lockId? // empty' | head -1)"
  fi
  [[ -n "${lock_id}" ]] || die "could not determine lock id for ${dep}; unlock it by hand before retrying"
  ok "locked (lock-id ${lock_id})"

  # Always release the lock, even if the import fails — a deployment left
  # locked cannot be applied and the id is awkward to recover.
  # shellcheck disable=SC2064
  trap "gcloud infra-manager deployments unlock '${dep}' --lock-id='${lock_id}' --project='${PROJECT_ID}' --location='${IM_LOCATION}' --quiet >/dev/null 2>&1 || true" RETURN

  info "importing ${file}…"
  im deployments import-statefile "${dep}" --lock-id="${lock_id}" --file="${file}"
  ok "state imported into ${dep}"

  # Read it straight back and compare — proves the upload landed, not just
  # that the command exited zero.
  local verify="${WORK_DIR}/${dep}.verify.tfstate"
  im deployments export-statefile "${dep}" --file="${verify}" >/dev/null
  if diff -q <(state_addresses "${file}") <(state_addresses "${verify}") >/dev/null; then
    ok "read-back matches: $(state_addresses "${verify}" | wc -l | tr -d ' ') addresses"
  else
    diff <(state_addresses "${file}") <(state_addresses "${verify}") | sed 's/^/      /' >&2
    die "read-back of ${dep} does not match what was uploaded (diff above)"
  fi
}

cmd_import() {
  bold "Importing split state"
  import_one "${INFRA_DEPLOYMENT}"     "${WORK_DIR}/infra.tfstate"
  import_one "${PLATFORMA_DEPLOYMENT}" "${WORK_DIR}/platforma.tfstate"
}

# -----------------------------------------------------------------------------
# preview — the zero-destroy gate
# -----------------------------------------------------------------------------
preview_one() {
  local dep="$1" tf_dir="$2" tfvars="$3"
  [[ -f "${tfvars}" ]] || die "missing ${tfvars} — see migration.md Phase 4 for how to produce it"

  local stage="${WORK_DIR}/preview-${dep}"
  rm -rf "${stage}"; mkdir -p "${stage}"
  # backend.tf is a local-development artefact; IM manages state itself and
  # rejects bundles carrying their own backend block.
  (cd "${tf_dir}" && tar cf - --exclude='.terraform' --exclude='backend.tf' .) | (cd "${stage}" && tar xf -)
  cp "${tfvars}" "${stage}/inputs.auto.tfvars.json"

  local preview_id="${dep}-mig-preview"
  info "creating preview ${preview_id}…"
  gcloud infra-manager previews create "${preview_id}" \
    --deployment="${dep}" \
    --local-source="${stage}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --project="${PROJECT_ID}" --location="${IM_LOCATION}" --quiet

  local changes destroys
  changes="$(gcloud infra-manager resource-changes list \
    --preview="${preview_id}" --project="${PROJECT_ID}" --location="${IM_LOCATION}" \
    --format=json)"
  echo "${changes}" > "${WORK_DIR}/${dep}.changes.json"

  destroys="$(echo "${changes}" | jq -r '[.[] | select(.intent // "" | test("DELETE|REPLACE"))] | length')"
  info "planned changes written to ${WORK_DIR}/${dep}.changes.json"
  echo "${changes}" | jq -r '.[] | "      \(.intent // "?")  \(.name // .address // "?")"' || true

  if [[ "${destroys}" != "0" ]]; then
    die "${dep}: preview plans ${destroys} destructive change(s) — STOP. See migration.md 'Reading a non-zero preview'."
  fi
  ok "${dep}: zero destructive changes"
}

cmd_preview() {
  bold "Previewing the real bundles against the imported state"
  preview_one "${INFRA_DEPLOYMENT}"     "${INFRA_TF_DIR}"     "${WORK_DIR}/inputs-infra.auto.tfvars.json"
  preview_one "${PLATFORMA_DEPLOYMENT}" "${PLATFORMA_TF_DIR}" "${WORK_DIR}/inputs-platforma.auto.tfvars.json"
  bold "Both previews are clean. Proceed to Phase 5 in migration.md."
}

# -----------------------------------------------------------------------------
# retire — static batch node pools, after the ComputeClass has taken over
# -----------------------------------------------------------------------------
# Prints commands; deliberately does NOT run them. Deleting a node pool drains
# every node in it, and only the operator can judge whether the ComputeClass is
# genuinely serving jobs yet.
cmd_retire() {
  bold "Static batch node pools — retirement plan"

  local golden="${WORK_DIR}/golden-monolith.tfstate"
  [[ -f "${golden}" ]] || die "no golden snapshot — run './migration.sh export' first"

  # Cluster name and LOCATION come from the state, not from a guess. The
  # monolith deploys a ZONAL cluster, so this is a zone (europe-west1-b), not
  # a region. Passing --region here would silently address a different (or
  # non-existent) cluster.
  local cluster location
  cluster="$(jq -r '.resources[] | select(.type=="google_container_cluster" and .name=="primary")
                    | .instances[0].attributes.name // empty' "${golden}")"
  location="$(jq -r '.resources[] | select(.type=="google_container_cluster" and .name=="primary")
                    | .instances[0].attributes.location // empty' "${golden}")"
  [[ -n "${cluster}" && -n "${location}" ]] \
    || die "could not read cluster name/location from ${golden}"
  info "cluster ${cluster} in ${location}"

  local pools
  pools="$(gcloud container node-pools list --cluster="${cluster}" \
             --location="${location}" --project="${PROJECT_ID}" \
             --format='value(name)' 2>/dev/null || true)"
  [[ -n "${pools}" ]] || die "could not list node pools on ${cluster}"

  local batch_pools
  batch_pools="$(echo "${pools}" | grep -E '^batch' || true)"
  if [[ -z "${batch_pools}" ]]; then
    ok "no static batch-* pools remain — nothing to retire"
    return 0
  fi

  warn "Do NOT run these until the ComputeClass is serving batch jobs. Check:"
  echo "      kubectl get nodes -L cloud.google.com/compute-class,role"
  echo "      # expect nodes carrying compute-class=platforma-batch, and no"
  echo "      # running job pods left on the batch-* nodes below."
  echo
  bold "Then, one pool at a time:"
  local p
  while read -r p; do
    [[ -n "${p}" ]] || continue
    echo "      gcloud container node-pools delete ${p} \\"
    echo "        --cluster=${cluster} --location=${location} --project=${PROJECT_ID}"
  done <<<"${batch_pools}"
  echo
  info "These pools are in no Terraform state after the split, so this is a"
  info "plain GCP cleanup — nothing to reconcile afterwards."
}

# -----------------------------------------------------------------------------
# reset — rehearsal only
# -----------------------------------------------------------------------------
cmd_reset() {
  bold "Resetting rehearsal targets"
  [[ "${ALLOW_RESET:-}" == "yes" ]] \
    || die "refusing without ALLOW_RESET=yes — this deletes the target IM deployments"

  local d
  for d in "${INFRA_DEPLOYMENT}" "${PLATFORMA_DEPLOYMENT}"; do
    [[ "$(deployment_state "${d}")" == "NOTFOUND" ]] && { info "${d} absent"; continue; }
    # --delete-policy=abandon leaves every cloud resource in place and removes
    # only IM's record of it. Without it, IM runs `terraform destroy`.
    info "deleting ${d} (abandon)…"
    im deployments delete "${d}" --delete-policy=abandon --quiet
    ok "${d} deleted, resources abandoned"
  done
  rm -f "${WORK_DIR}"/{infra,platforma}.tfstate "${WORK_DIR}"/*.verify.tfstate "${WORK_DIR}"/*.changes.json
  ok "work dir cleaned (golden snapshot kept)"
}

# -----------------------------------------------------------------------------
usage() {
  # Print the leading comment block (everything after the shebang up to the
  # first line of actual code).
  awk 'NR==1 {next} !/^#/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  preflight|export|classify|split|seed|import|preview|retire|reset) require_config ;;
esac

case "${1:-}" in
  preflight) cmd_preflight ;;
  export)    cmd_export ;;
  classify)  cmd_classify ;;
  split)     cmd_split ;;
  seed)      cmd_seed ;;
  import)    cmd_import ;;
  preview)   cmd_preview ;;
  retire)    cmd_retire ;;
  reset)     cmd_reset ;;
  *)         usage; exit 1 ;;
esac
