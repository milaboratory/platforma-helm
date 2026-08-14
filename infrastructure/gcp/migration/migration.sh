#!/usr/bin/env bash
# =============================================================================
# migration.sh — split a monolithic GCP Platforma deployment into the
#                terraform-infra + terraform-platforma pair
# =============================================================================
# See ../migration.md for the full procedure, the rationale, and the rollback
# path.
#
#   ./migration.sh preflight   # tooling, auth, deployment states
#   ./migration.sh export      # monolith state -> work dir (source of import IDs)
#   ./migration.sh classify    # completeness check; prints the partition
#   ./migration.sh generate    # stage each half: real bundle + inputs + imports.tf
#   ./migration.sh preview     # read-only adoption plan; the zero-destroy gate
#   ./migration.sh apply       # AFTER review: adopt each half (create + import)
#   ./migration.sh cutover     # AFTER apply: abandon the monolith deployment
#   ./migration.sh retire      # AFTER cutover: retire static batch pools, if any
#
# How adoption works
# ------------------
#
# Configure script to point your installation:
#  PROJECT_ID - GCP project holding the monolith deployment
#  DEPLOYMENT_NAME - existing monolith IM deployment name
#  IM_LOCATION - location (--location) of the monolith IM deployment
#
# Run commands in sequence they are shown in help. Steps before 'apply' are all
# read-only for cloud resources: they read state of deployment, create local files
# and perform verification of what is going to be done.
#
# First real step that changes cluster deployments and can make harm is is 'apply',
# which creates new deployments on top of existing resources and configures them to
# be aligned with the new configuration.
#
# 'preview' shows what 'apply' will do. To see full diff of changes, run
# 'preview' with SHOW_DIFF=true environment variable, or see diff-file
# reported after preview finished.
#
# We recommend to run cloudshell 'install.sh' script after 'apply' and before
# 'cutover' and check if everything is working as expected.
#
# 'cutover' deletes old monolith deployment, keeping all resources it created
# in place. 'cutover' and 'retire' are final steps that make new deployments to
# be the source of truth.
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-}"
IM_LOCATION="${IM_LOCATION:-europe-west1}"
IM_SA_EMAIL="${IM_SA_EMAIL:-platforma-im-deployer@${PROJECT_ID}.iam.gserviceaccount.com}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR_OVERRIDE="${WORK_DIR:-}"
GEN_IMPORTS_JQ="${SCRIPT_DIR}/gen-imports.jq"

# Real module bundles + the installer we borrow input projection from.
GCP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_TF_DIR="${GCP_DIR}/terraform-infra"
PLATFORMA_TF_DIR="${GCP_DIR}/terraform-platforma"
REPO_ROOT="$(cd "${GCP_DIR}/../.." && pwd)"
CHART_DIR="${REPO_ROOT}/charts/platforma"
INSTALL_SH="${GCP_DIR}/cloudshell/install.sh"

# -----------------------------------------------------------------------------
# The partition
# -----------------------------------------------------------------------------
# `classify` asserts every managed address in the exported state appears in
# exactly one of these lists. Adding a resource to a module later fails loudly
# here instead of silently orphaning it.

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

# -- No importer (state-only, no cloud object). Left OUT of imports.tf so they
#    are recreated on the adopting apply; the preview reports them as CREATEs,
#    which is expected and harmless. They still belong to a half (they appear in
#    KEEP_PLATFORMA above), so classify still accounts for them.
SKIP_IMPORT=(
  null_resource
  terraform_data
)

# -- Dropped from BOTH halves. The cloud objects are NOT destroyed; they simply
#    stop being Terraform-managed. terraform-platforma reads the master secret
#    through data.google_secret_manager_secret_version instead of owning it.
DROP=(
  random_id.master_secret
  google_secret_manager_secret.master_secret
  google_secret_manager_secret_version.master_secret
)

# -- Destructive changes the operator has REVIEWED and consented to. The preview
#    gate warns on these but does not block; any OTHER destructive change still
#    hard-stops. Keep this list tight and justify every entry.
#
#    random_password.admin: terraform-platforma adds override_special, which the
#    live (monolith-created) password lacks — a ForceNew for the random provider.
#    Adoption therefore ROTATES the admin password. Accepted: the new password is
#    published to the admin-password Secret Manager secret, so it stays
#    retrievable; only a cached copy of the old one goes stale. The dependent
#    secret version is recreated for the same reason.
#    google_container_node_pool.system: the monolith created it with 2 nodes;
#    terraform-infra's default is 1. initial_node_count is immutable and the pool
#    does not autoscale, so adoption reduces it to 1 with a one-time drain +
#    recreate DURING the migration window. Accepted deliberately so that a normal
#    install.sh run afterward — which also uses the default of 1 — is a clean
#    no-op instead of springing this replacement on the operator later.
ACCEPT_REPLACE=(
  random_password.admin
  google_secret_manager_secret_version.admin_password
  google_container_node_pool.system
)

# -- Resources the split modules add that the monolith never had. They appear in
#    the preview as CREATEs — a known, intended difference between the old
#    monolith and the current two-module layout, NOT a failed import. Reported in
#    their own group so a genuinely unexpected CREATE still stands out.
#    (terraform-infra adds an Artifact Registry repo for pl-containers, its
#    reader IAM, and the artifactregistry API that backs it.)
KNOWN_NEW=(
  google_artifact_registry_repository.pl_containers
  google_artifact_registry_repository_iam_member.pl_containers_server_reader
  google_artifact_registry_repository_iam_member.pl_containers_jobs_reader
  'google_project_service.enabled["artifactregistry.googleapis.com"]'
)

# -- Dropped from both halves AND scheduled for manual deletion afterwards.
#    Static batch node pools predating the batch ComputeClass migration. Absent
#    from a recently-migrated monolith (classify reports them listed-but-absent,
#    which is expected).
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

  INFRA_DEPLOYMENT="${DEPLOYMENT_NAME}-infra"
  PLATFORMA_DEPLOYMENT="${DEPLOYMENT_NAME}-platforma"
  WORK_DIR="${WORK_DIR_OVERRIDE:-${SCRIPT_DIR}/.work/${PROJECT_ID}-${DEPLOYMENT_NAME}}"
  GOLDEN="${WORK_DIR}/golden-monolith.tfstate"
}

im() { gcloud infra-manager "$@" --project="${PROJECT_ID}" --location="${IM_LOCATION}"; }

deployment_state() {
  im deployments describe "$1" --format='value(state)' 2>/dev/null || echo NOTFOUND
}

# Base addresses of all managed resources in a state file, sorted and unique.
state_addresses() {
  jq -r '.resources[] | select(.mode=="managed") | "\(.type).\(.name)"' "$1" | sort -u
}

# Export a deployment's statefile to exactly $2. Some gcloud releases append a
# '.tfstate' suffix to --file; normalise either name to the requested path.
export_statefile() {
  local dep="$1" out="$2"
  im deployments export-statefile "${dep}" --file="${out}"
  if [[ ! -f "${out}" && -f "${out}.tfstate" ]]; then
    mv "${out}.tfstate" "${out}"
  fi
  [[ -f "${out}" ]] || die "export-statefile did not produce ${out}"
}

# A bash array of KEEP addresses -> a JSON array (for gen-imports.jq).
addrs_to_json() { printf '%s\n' "$@" | jq -R . | jq -s .; }

# Render a resource-changes JSON document to a readable per-property diff,
# grouped by resource and action. "(known after apply)" values are Terraform's,
# not ours.
render_full_diff() {
  local changes_json="$1" out="$2"
  jq -r '
    def v(x): if x == null then "null" else (x | tojson) end;
    .[]
    | .terraformInfo as $ti
    | "### \($ti.address)  [\($ti.actions | join("+"))]",
      ( .propertyChanges[]? | "    \(.path): \(v(.before)) -> \(v(.after))" ),
      ""
  ' "${changes_json}" > "${out}"
}

# Rewrite import targets through the bundle's `moved {}` blocks. A refactor may
# rename a resource (moved from = OLD, to = NEW); the monolith state still holds
# OLD, so gen-imports emits `to = OLD`. Terraform rejects importing to a move
# source, so replace OLD with NEW in the generated import blocks.
remap_moved() {
  local bundle_dir="$1" imports="$2"
  local moved
  moved="$(awk '
    /^[[:space:]]*moved[[:space:]]*{/ { inm=1; from=""; to=""; next }
    inm && /from[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/,""); sub(/[[:space:]]+$/,""); from=$0 }
    inm && /to[[:space:]]*=/   { sub(/^[^=]*=[[:space:]]*/,""); sub(/[[:space:]]+$/,""); to=$0 }
    inm && /}/ { inm=0; if (from!="" && to!="") print from "\t" to }
  ' "${bundle_dir}"/*.tf 2>/dev/null)"
  [[ -n "${moved}" ]] || return 0
  local from to
  while IFS=$'\t' read -r from to; do
    [[ -n "${from}" && -n "${to}" ]] || continue
    # Literal (not regex) replacement of the whole `to = OLD` line.
    python3 - "${imports}" "${from}" "${to}" <<'PY'
import sys
path, frm, to = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
s = s.replace("  to = " + frm + "\n", "  to = " + to + "\n")
open(path, "w").write(s)
PY
    info "remapped import target (moved): ${from} → ${to}"
  done <<< "${moved}"
}

# -----------------------------------------------------------------------------
# Inputs: reuse install.sh's per-half tfvars projection, fed by the monolith's
# own recorded inputs (so the adopting apply plans against the same values the
# monolith was built with).
# -----------------------------------------------------------------------------

# Download the monolith deployment's source bundle and cache its
# inputs.auto.tfvars.json (the full input document install.sh embedded).
extract_monolith_inputs() {
  local out="${WORK_DIR}/monolith-inputs.full.json"
  if [[ ! -f "${out}" ]]; then
    local src base tmp f
    src="$(im deployments describe "${DEPLOYMENT_NAME}" --format='value(terraformBlueprint.gcsSource)' 2>/dev/null || true)"
    [[ -n "${src}" ]] || die "monolith ${DEPLOYMENT_NAME} has no gcsSource; cannot read its inputs"
    base="${src%%#*}"
    tmp="$(mktemp -d)"
    gsutil -q cp "${base}" "${tmp}/bundle.zip" || die "cannot download monolith bundle ${base}"
    ( cd "${tmp}" && unzip -oq bundle.zip )
    f="$(find "${tmp}" -maxdepth 2 -name 'inputs.auto.tfvars.json' | head -1)"
    [[ -f "${f}" ]] || die "monolith bundle has no inputs.auto.tfvars.json"
    cp "${f}" "${out}"
    rm -rf "${tmp}"
  fi
  echo "${out}"
}

# Project the monolith inputs to just the keys one half declares, reusing
# install.sh's build_tfvars_json_{infra,platforma}. install.sh is sourced in a
# subshell (its EXIT trap + temp dir stay contained), and its value source
# build_tfvars_json_full is overridden to emit the monolith's real inputs plus
# the bring-your-own master_secret_secret_id.
build_half_inputs() {
  local half="$1" out="$2"
  local full fulldoc msid gcs fs
  full="$(extract_monolith_inputs)"
  msid="${DEPLOYMENT_NAME}-cluster-platforma-master-secret"

  # We deliberately do NOT pin system_pool_node_count here. terraform-infra's
  # default (2) matches the live pool created by the monolith, so adoption is
  # in-place — and, crucially, install.sh uses the SAME default, so a normal
  # install.sh run after migration is a no-op instead of replacing the pool.
  # Injecting a value here would make migration and install.sh disagree.
  fulldoc="${WORK_DIR}/monolith-inputs.withmsid.json"
  jq --arg m "${msid}" '. + {master_secret_secret_id: $m}' "${full}" > "${fulldoc}"
  gcs="$(jq -r '.resources[]|select(.type=="google_storage_bucket" and .name=="primary")|.instances[0].attributes.name' "${GOLDEN}")"
  fs="$(jq -r '.resources[]|select(.type=="google_filestore_instance" and .name=="workspace")|.instances[0].attributes.name' "${GOLDEN}")"
  (
    # shellcheck disable=SC1090
    source "${INSTALL_SH}"
    build_tfvars_json_full() { cat "${fulldoc}" > "$1"; }
    INFRA_OUT_GCS_BUCKET="${gcs}"
    INFRA_OUT_FILESTORE_INSTANCE_NAME="${fs}"
    case "${half}" in
      infra)     build_tfvars_json_infra     "${out}" ;;
      platforma) build_tfvars_json_platforma "${out}" ;;
    esac
  )
  [[ -s "${out}" ]] || die "failed to build ${half} inputs"
}

# -----------------------------------------------------------------------------
# preflight
# -----------------------------------------------------------------------------
cmd_preflight() {
  bold "Preflight"

  for t in gcloud jq gsutil unzip; do
    command -v "$t" >/dev/null || die "'$t' not found on PATH"
  done
  ok "gcloud, jq, gsutil, unzip present"

  [[ -f "${GEN_IMPORTS_JQ}" ]] || die "missing ${GEN_IMPORTS_JQ}"
  [[ -f "${INSTALL_SH}" ]]     || die "missing ${INSTALL_SH}"
  [[ -d "${INFRA_TF_DIR}" ]]     || die "missing ${INFRA_TF_DIR}"
  [[ -d "${PLATFORMA_TF_DIR}" ]] || die "missing ${PLATFORMA_TF_DIR}"
  ok "generator, installer, and both bundles present"

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

  local d st
  for d in "${INFRA_DEPLOYMENT}" "${PLATFORMA_DEPLOYMENT}"; do
    st="$(deployment_state "${d}")"
    if [[ "${st}" == "NOTFOUND" ]]; then
      ok "target ${d} does not exist yet (expected)"
    else
      warn "target ${d} already exists (state: ${st}) — see 'Re-running' in migration.md"
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
    export_statefile "${DEPLOYMENT_NAME}" "${out}"
    ok "exported to ${out}"
  fi

  # The golden copy. gen-imports reads THIS; nothing writes to it again.
  [[ -f "${GOLDEN}" ]] || cp "${out}" "${GOLDEN}"
  chmod 0400 "${GOLDEN}"
  ok "golden snapshot ${GOLDEN} (read-only)"

  info "resources under management: $(state_addresses "${out}" | wc -l | tr -d ' ') distinct addresses"
}

# -----------------------------------------------------------------------------
# classify — the completeness gate
# -----------------------------------------------------------------------------
cmd_classify() {
  bold "Classifying monolith resources"
  local src="${GOLDEN}"
  [[ -f "${src}" ]] || die "no exported state — run './migration.sh export' first"

  local all known unclassified missing
  all="$(state_addresses "${src}")"
  known="$(printf '%s\n' "${KEEP_INFRA[@]}" "${KEEP_PLATFORMA[@]}" "${DROP[@]}" "${RETIRE[@]}" | sort -u)"

  unclassified="$(comm -23 <(echo "${all}") <(echo "${known}"))"
  missing="$(comm -13 <(echo "${all}") <(echo "${known}"))"

  info "in state:                    $(echo "${all}" | grep -c . || true)"
  info "→ terraform-infra:            ${#KEEP_INFRA[@]}"
  info "→ terraform-platforma:        ${#KEEP_PLATFORMA[@]}"
  info "  (of which recreated, not imported: ${#SKIP_IMPORT[@]} types)"
  info "→ dropped (kept in GCP):      ${#DROP[@]}"
  info "→ unmanaged, retire by hand:  ${#RETIRE[@]}"

  if [[ -n "${unclassified}" ]]; then
    warn "these addresses exist in the state but are in NO list:"
    echo "${unclassified}" | sed 's/^/      /' >&2
    die "refusing to proceed — classify every address above, then re-run"
  fi
  ok "every address in the state is classified"

  if [[ -n "${missing}" ]]; then
    warn "these addresses are listed but absent from the state. Expected for"
    warn "count/for_each-gated resources and for RETIRE on an already-migrated"
    warn "monolith. Anything else is suspicious:"
    echo "${missing}" | sed 's/^/      /' >&2
  fi

  bold "Dropped from Terraform management (cloud objects preserved):"
  printf '      %s\n' "${DROP[@]}"
}

# -----------------------------------------------------------------------------
# generate — stage each half: real bundle + projected inputs + imports.tf
# -----------------------------------------------------------------------------
generate_one() {
  local half="$1" tf_dir="$2"
  local stage="${WORK_DIR}/bundle-${half}"
  rm -rf "${stage}"; mkdir -p "${stage}"

  # Assemble the bundle exactly like install.sh's submit_deployment:
  #  - drop backend.tf (IM manages state itself and rejects a backend block)
  #  - drop dev-only artefacts
  (cd "${tf_dir}" && tar cf - \
      --exclude='.terraform' --exclude='backend.tf' \
      --exclude='terraform.tfvars' --exclude='tfplan' --exclude='errored.tfstate' . ) \
    | (cd "${stage}" && tar xf -)

  # The platforma module references the chart at ../../../charts/platforma;
  # bundle it and rewrite the path for the IM context (mirrors submit_deployment).
  if [[ "${half}" == "platforma" && -z "${HELM_CHART_REPOSITORY:-}" ]]; then
    cp -R "${CHART_DIR}" "${stage}/platforma"
    if grep -q '"${path.module}/../../../charts/platforma"' "${stage}/app.tf" 2>/dev/null; then
      sed -i.bak 's|"${path.module}/../../../charts/platforma"|"${path.module}/platforma"|' "${stage}/app.tf"
      rm -f "${stage}/app.tf.bak"
    fi
  fi

  # Projected inputs.
  build_half_inputs "${half}" "${stage}/inputs.auto.tfvars.json"

  # Import blocks. The file name sorts last so it is obvious in the bundle.
  local keep_json skip_json
  if [[ "${half}" == "infra" ]]; then
    keep_json="$(addrs_to_json "${KEEP_INFRA[@]}")"
  else
    keep_json="$(addrs_to_json "${KEEP_PLATFORMA[@]}")"
  fi
  skip_json="$(addrs_to_json "${SKIP_IMPORT[@]}")"
  jq -r --argjson keep "${keep_json}" --argjson skip "${skip_json}" \
     -f "${GEN_IMPORTS_JQ}" "${GOLDEN}" > "${stage}/zzz-adoption-imports.tf"
  remap_moved "${stage}" "${stage}/zzz-adoption-imports.tf"

  local n; n="$(grep -c '^import {' "${stage}/zzz-adoption-imports.tf" || true)"
  ok "${half}: staged bundle + $(jq 'length' "${stage}/inputs.auto.tfvars.json") inputs + ${n} import blocks → ${stage}"
}

cmd_generate() {
  bold "Generating adoption bundles"
  [[ -f "${GOLDEN}" ]] || die "no golden state — run './migration.sh export' first"
  cmd_classify >/dev/null   # completeness gate before we build anything
  generate_one infra     "${INFRA_TF_DIR}"
  generate_one platforma "${PLATFORMA_TF_DIR}"
  info "review the import blocks before previewing:"
  info "  ${WORK_DIR}/bundle-infra/zzz-adoption-imports.tf"
  info "  ${WORK_DIR}/bundle-platforma/zzz-adoption-imports.tf"
}

# -----------------------------------------------------------------------------
# preview — the read-only, zero-destroy adoption gate
# -----------------------------------------------------------------------------
preview_one() {
  local half="$1" dep="$2"
  local stage="${WORK_DIR}/bundle-${half}"
  [[ -d "${stage}" ]] || die "no staged bundle for ${half} — run './migration.sh generate' first"

  local pv="${dep}-adopt-preview"
  info "creating preview ${pv} (read-only; the target deployment need not exist)…"
  im previews delete "${pv}" --quiet >/dev/null 2>&1 || true
  im previews create "${pv}" \
    --local-source="${stage}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --quiet

  local changes
  changes="$(im resource-changes list --preview="${pv}" --format=json)"
  echo "${changes}" > "${WORK_DIR}/${half}.changes.json"

  bold "  ${half}: planned intents"
  echo "${changes}" | jq -r 'group_by(.intent)[] | "      \(.[0].intent): \(length)"'

  # The addresses we told Terraform to adopt (from the generated import blocks).
  local imported_json
  imported_json="$(grep -E '^[[:space:]]*to = ' "${stage}/zzz-adoption-imports.tf" \
                   | sed -E 's/^[[:space:]]*to = //' | jq -R . | jq -s .)"

  # Destructive = any change whose Terraform actions include "delete" (DELETE and
  # RECREATE both carry it). Split into operator-accepted (ACCEPT_REPLACE) and
  # unexpected. The base address (index stripped) is matched against the list.
  local accept_json accepted_destroyers destroyers
  accept_json="$(addrs_to_json "${ACCEPT_REPLACE[@]}")"
  accepted_destroyers="$(echo "${changes}" | jq -r --argjson acc "${accept_json}" '
    [ .[] | select(.terraformInfo.actions | index("delete"))
          | .terraformInfo.address
          | select( (sub("\\[.*\\]$";"")) as $b | ($acc | index($b)) )
          | "\(.)" ] | .[]')"
  destroyers="$(echo "${changes}" | jq -r --argjson acc "${accept_json}" '
    [ .[] | select(.terraformInfo.actions | index("delete"))
          | select( (.terraformInfo.address | sub("\\[.*\\]$";"")) as $b | ($acc | index($b)) | not )
          | "\(.terraformInfo.address) [\(.terraformInfo.actions | join("+"))]" ] | .[]')"

  if [[ -n "${accepted_destroyers}" ]]; then
    warn "  ${half}: these resources WILL BE REPLACED during migration. After the"
    warn "  migration you can run install.sh to update the configuration to what"
    warn "  you need:"
    echo "${accepted_destroyers}" | sed 's/^/        REPLACE  /' >&2
  fi

  # CREATEs fall into four buckets:
  #   bad       — a CREATE on an address we meant to IMPORT; the import id did
  #               not match a live resource, so an apply would make a duplicate.
  #   known-new — a resource the split adds that the monolith never had
  #               (KNOWN_NEW): an intended monolith→split difference.
  #   state     — a state-only resource with no importer (SKIP_IMPORT types),
  #               recreated with no cloud object.
  #   surprise  — anything else: report loudly so a missing import stands out.
  local known_json skip_types_json bad_creates known_creates state_creates surprise_creates
  known_json="$(addrs_to_json "${KNOWN_NEW[@]}")"
  skip_types_json="$(addrs_to_json "${SKIP_IMPORT[@]}")"
  bad_creates="$(echo "${changes}" | jq -r --argjson imp "${imported_json}" '
    [ .[] | select(.terraformInfo.actions == ["create"])
          | .terraformInfo.address | select(. as $a | $imp | index($a)) ] | .[]')"
  known_creates="$(echo "${changes}" | jq -r --argjson known "${known_json}" '
    [ .[] | select(.terraformInfo.actions == ["create"])
          | .terraformInfo.address as $a
          | select($known | index($a)) | $a ] | .[]')"
  state_creates="$(echo "${changes}" | jq -r --argjson known "${known_json}" --argjson skip "${skip_types_json}" '
    [ .[] | select(.terraformInfo.actions == ["create"])
          | .terraformInfo as $ti
          | select(($known | index($ti.address) | not) and ($skip | index($ti.type)))
          | $ti.address ] | .[]')"
  surprise_creates="$(echo "${changes}" | jq -r --argjson imp "${imported_json}" --argjson known "${known_json}" --argjson skip "${skip_types_json}" '
    [ .[] | select(.terraformInfo.actions == ["create"])
          | .terraformInfo as $ti
          | select(($imp   | index($ti.address) | not)
                   and ($known | index($ti.address) | not)
                   and ($skip  | index($ti.type)    | not))
          | $ti.address ] | .[]')"

  if [[ -n "${known_creates}" ]]; then
    warn "  ${half}: new resources known to be created during migration (a known"
    warn "  difference between the old monolith and the current split):"
    echo "${known_creates}" | sed 's/^/        CREATE  /' >&2
  fi
  if [[ -n "${state_creates}" ]]; then
    warn "  ${half}: state-only resources recreated (no importer, no cloud object):"
    echo "${state_creates}" | sed 's/^/        CREATE  /' >&2
  fi
  if [[ -n "${surprise_creates}" ]]; then
    warn "  ${half}: unexpected CREATE(s) — not import-blocked, not a known new or"
    warn "  state-only resource. A real resource here means a missing import. Review:"
    echo "${surprise_creates}" | sed 's/^/        CREATE  /' >&2
  fi

  local fail=0
  if [[ -n "${bad_creates}" ]]; then
    warn "  ${half}: these addresses have an import block but plan a CREATE — the"
    warn "  import did not match a live resource (wrong id) → duplicate risk:"
    echo "${bad_creates}" | sed 's/^/        CREATE  /' >&2
    fail=1
  fi
  if [[ -n "${destroyers}" ]]; then
    warn "  ${half}: destructive changes planned:"
    echo "${destroyers}" | sed 's/^/        /' >&2
    fail=1
  fi
  # Full per-property diff, always written; printed inline when SHOW_DIFF is set.
  # The raw `terraform plan` text is also in the preview's Cloud Build log
  # (Cloud Build console, or the deployment's blueprint-config GCS bucket).
  local difffile="${WORK_DIR}/${half}.diff.txt"
  render_full_diff "${WORK_DIR}/${half}.changes.json" "${difffile}"
  if [[ -n "${SHOW_DIFF:-}" ]]; then
    bold "  ${half}: full property diff"
    sed 's/^/    /' "${difffile}" >&2
  fi

  [[ "${fail}" == "0" ]] \
    || die "${half}: preview is NOT safe to apply — see above. Full diff: ${difffile}"

  ok "${half}: no unexpected destructive changes, no failed imports"
  info "  intents: ${WORK_DIR}/${half}.changes.json   full diff: ${difffile}   (SHOW_DIFF=1 to print)"
}

cmd_preview() {
  bold "Previewing adoption (read-only)"
  preview_one infra     "${INFRA_DEPLOYMENT}"
  preview_one platforma "${PLATFORMA_DEPLOYMENT}"
  bold "Both previews are clean. Review the CREATE/UPDATE lists, then './migration.sh apply'."
}

# -----------------------------------------------------------------------------
# apply — adopt each half (create the deployment; import blocks read existing
#         resources into state instead of creating them)
# -----------------------------------------------------------------------------
apply_one() {
  local half="$1" dep="$2"
  local stage="${WORK_DIR}/bundle-${half}"
  [[ -d "${stage}" ]] || die "no staged bundle for ${half} — run './migration.sh generate' first"

  local st; st="$(deployment_state "${dep}")"
  [[ "${st}" == "NOTFOUND" ]] \
    || die "${dep} already exists (${st}); adoption creates it fresh. See migration.md 'Re-running'."

  info "applying ${dep} (adopts ${half} resources)…"
  im deployments apply "${dep}" \
    --local-source="${stage}" \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${IM_SA_EMAIL}" \
    --quiet
  st="$(deployment_state "${dep}")"
  [[ "${st}" == "ACTIVE" ]] || die "${dep} settled in state ${st}, expected ACTIVE — inspect Cloud Build logs"
  ok "${dep} ACTIVE — resources adopted"
}

cmd_apply() {
  bold "Adopting resources into the split deployments"
  warn "This creates the target deployments. It is safe (import, not create), but"
  warn "run './migration.sh preview' first and confirm zero destructive changes."
  apply_one infra     "${INFRA_DEPLOYMENT}"
  apply_one platforma "${PLATFORMA_DEPLOYMENT}"
  bold "Both halves adopted. Verify the app, then './migration.sh cutover'."
}

# -----------------------------------------------------------------------------
# cutover — stop the monolith managing the now-adopted resources
# -----------------------------------------------------------------------------
cmd_cutover() {
  bold "Cutover: abandoning the monolith deployment"
  local st; st="$(deployment_state "${DEPLOYMENT_NAME}")"
  [[ "${st}" != "NOTFOUND" ]] || { ok "monolith ${DEPLOYMENT_NAME} already gone"; return 0; }

  for d in "${INFRA_DEPLOYMENT}" "${PLATFORMA_DEPLOYMENT}"; do
    [[ "$(deployment_state "${d}")" == "ACTIVE" ]] \
      || die "${d} is not ACTIVE — do not abandon the monolith until both halves are adopted"
  done
  ok "both split halves are ACTIVE"

  # --delete-policy=abandon removes only IM's record; every cloud resource stays
  # (the split deployments now manage them).
  info "abandoning ${DEPLOYMENT_NAME} (no resources destroyed)…"
  im deployments delete "${DEPLOYMENT_NAME}" --delete-policy=abandon --quiet
  ok "monolith ${DEPLOYMENT_NAME} abandoned; the split deployments are now authoritative"
}

# -----------------------------------------------------------------------------
# retire — static batch node pools, after the ComputeClass has taken over
# -----------------------------------------------------------------------------
cmd_retire() {
  bold "Static batch node pools — retirement plan"

  local golden="${GOLDEN}"
  [[ -f "${golden}" ]] || die "no golden snapshot — run './migration.sh export' first"

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
  echo
  bold "Then, one pool at a time:"
  local p
  while read -r p; do
    [[ -n "${p}" ]] || continue
    echo "      gcloud container node-pools delete ${p} \\"
    echo "        --cluster=${cluster} --location=${location} --project=${PROJECT_ID}"
  done <<<"${batch_pools}"
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
    # abandon = drop IM's record, leave every cloud resource in place.
    info "deleting ${d} (abandon)…"
    im deployments delete "${d}" --delete-policy=abandon --quiet
    ok "${d} deleted, resources abandoned"
  done
  for d in "${INFRA_DEPLOYMENT}" "${PLATFORMA_DEPLOYMENT}"; do
    im previews delete "${d}-adopt-preview" --quiet >/dev/null 2>&1 || true
  done
  rm -rf "${WORK_DIR}"/bundle-infra "${WORK_DIR}"/bundle-platforma \
         "${WORK_DIR}"/*.changes.json "${WORK_DIR}"/monolith-inputs.*.json
  ok "work dir cleaned (golden snapshot kept)"
}

# -----------------------------------------------------------------------------
usage() {
  awk 'NR==1 {next} !/^#/ {exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  preflight|export|classify|generate|preview|apply|cutover|retire|reset) require_config ;;
esac

case "${1:-}" in
  preflight) cmd_preflight ;;
  export)    cmd_export ;;
  classify)  cmd_classify ;;
  generate)  cmd_generate ;;
  preview)   cmd_preview ;;
  apply)     cmd_apply ;;
  cutover)   cmd_cutover ;;
  retire)    cmd_retire ;;
  reset)     cmd_reset ;;
  *)         usage; exit 1 ;;
esac
