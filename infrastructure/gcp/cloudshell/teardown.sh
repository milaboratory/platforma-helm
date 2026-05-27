#!/usr/bin/env bash
# =============================================================================
# Platforma on GCP — Infrastructure Manager teardown
# =============================================================================
# Cleans up an IM deployment created by install.sh:
#
#   1. Force-deletes the chart's PVCs (workspace, database, logs) before the
#      IM destroy starts. These have helm.sh/resource-policy=keep so helm
#      uninstall leaves them alone — but terraform then tries to delete the
#      PVs anyway and hangs for ~30 min on kubernetes.io/pv-protection
#      finalizers, leaving the cluster + Filestore + network behind.
#   2. Submits 'gcloud infra-manager deployments delete' with delete-policy.
#   3. Waits for the deletion to finish and reports the outcome.
#
# Run instead of the raw 'gcloud infra-manager deployments delete' when
# tearing down a deployment that contains the platforma chart.
#
# Inputs (same env vars install.sh uses; missing values prompt or auto-detect):
#   PROJECT_ID          GCP project (defaults to gcloud config)
#   DEPLOYMENT_NAME     IM deployment name           (default: platforma)
#   IM_LOCATION         IM deployment region         (default: europe-west1)
#   CLUSTER_NAME        GKE cluster name             (default: ${DEPLOYMENT_NAME}-cluster)
#   PLATFORMA_NAMESPACE Namespace holding chart PVCs (default: platforma)
# =============================================================================

set -euo pipefail

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info()  { printf '  \033[36m→\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { red "Required command '$1' not found in PATH."; exit 1; }
}

# Strong-confirmation prompt for destructive actions. Operator must type the
# expected phrase verbatim (case-sensitive) to proceed — same UX pattern as
# GitHub's "type the repo name to delete" confirm box. Empty input or any
# mismatch aborts. Exits 0 (clean abort) rather than 1 because the operator
# intentionally backed out, not an error condition.
require_phrase() {
  local expected="$1"
  echo
  bold "Confirm destructive action"
  red   "  This will permanently delete the deployment and its data."
  echo  "  Type exactly the following to proceed (or anything else to abort):"
  echo  "    ${expected}"
  echo
  local input
  read -r -p "  Confirmation: " input
  if [[ "${input}" != "${expected}" ]]; then
    red "  Phrase did not match — aborting."
    exit 0
  fi
  echo
}

# -----------------------------------------------------------------------------
# Inputs
# -----------------------------------------------------------------------------

resolve_inputs() {
  bold "Teardown inputs"

  require_command gcloud
  require_command kubectl

  PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
  if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    red "No active GCP project. Run: gcloud config set project YOUR_PROJECT"
    exit 1
  fi

  DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-platforma}"
  IM_LOCATION="${IM_LOCATION:-europe-west1}"
  CLUSTER_NAME="${CLUSTER_NAME:-${DEPLOYMENT_NAME}-cluster}"
  PLATFORMA_NAMESPACE="${PLATFORMA_NAMESPACE:-platforma}"

  info "Project:        ${PROJECT_ID}"
  info "Deployment:     ${DEPLOYMENT_NAME}  (IM location: ${IM_LOCATION})"
  info "Cluster:        ${CLUSTER_NAME}"
  info "Namespace:      ${PLATFORMA_NAMESPACE}"
  echo
}

# -----------------------------------------------------------------------------
# PVC cleanup
# -----------------------------------------------------------------------------
# The chart annotates its PVCs with helm.sh/resource-policy=keep so production
# operators don't lose data on accidental 'helm uninstall'. For a full
# teardown we want them gone — otherwise the terraform helm provider hangs
# trying to delete the PVs (kubernetes.io/pv-protection finalizer holds the
# PV while a PVC is still Bound).
#
# Sequence:
#   1. Auto-detect the cluster's zone, fetch kubeconfig.
#   2. Scale the platforma Deployment to 0 and wait for pods to drain —
#      otherwise pvc-protection finalizer holds the PVCs while the pod is
#      still mounting them, and the force-clear fallback below would rip
#      volumes out from under a running, possibly-still-writing pod.
#   3. Delete the PVCs.
#   4. Poll up to 2 min for pvc-protection finalizers to clear naturally
#      (typical ~10s once no pods are mounting).
#   5. Force-remove finalizers as a last resort — safe at this point
#      because pods are gone and no writes are in flight.
cleanup_pvcs() {
  bold "Cleaning up chart PVCs before IM destroy"

  local zone
  zone=$(gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --filter="name=${CLUSTER_NAME}" \
    --format="value(location)" 2>/dev/null | head -1)

  if [[ -z "${zone}" ]]; then
    info "Cluster ${CLUSTER_NAME} not found in ${PROJECT_ID} — assuming already torn down or partially destroyed. Skipping PVC cleanup."
    echo
    return 0
  fi

  info "Authenticating kubectl to ${CLUSTER_NAME} (${zone})…"
  # --location accepts both zone (zonal cluster) and region (regional cluster)
  # identifiers; --zone would 400 on a regional cluster because gcloud's list
  # output 'value(location)' returns the region in that case.
  # Don't swallow stderr — a failure here (wrong perms, transient API) needs
  # to surface to the operator; otherwise 'set -e' exits silently.
  if ! gcloud container clusters get-credentials "${CLUSTER_NAME}" \
       --location="${zone}" --project="${PROJECT_ID}" --quiet; then
    red "Failed to fetch kubeconfig for ${CLUSTER_NAME} in ${zone}."
    red "Common causes: wrong project, missing container.clusters.get IAM, transient API."
    red "Skipping PVC cleanup; proceeding to IM delete (terraform will surface any remaining state)."
    echo
    return 0
  fi

  local ctx
  ctx=$(kubectl config current-context)

  # Scale the platforma Deployment to 0 BEFORE deleting PVCs. Without this,
  # the running pod mounts the PVCs and kubernetes.io/pvc-protection
  # finalizer holds them in 'Terminating' state until the pod is gone. The
  # poll loop below would never see them clear, fall through to the
  # force-finalizer-clear path, and rip PVCs out from under a still-writing
  # pod — risking data corruption on the database PVC and confused logs on
  # logs/workspace mounts.
  #
  # Match by label rather than name. The chart renders the Deployment as
  # '<release_name>-<chart_name>' unless one or both happen to be 'platforma'
  # (the terraform module's default). Targeting by name would silently skip
  # the scale step on any deployment that customised helm_release_name.
  # Track whether the chart's pods actually drained. If they did, the
  # force-finalizer-clear fallback below is safe (no writes in flight).
  # If they didn't, force-clearing PVCs while a pod is still writing risks
  # data corruption — refuse to do it and tell the operator how to recover
  # manually. Default 1 (no Deployment present ⇒ nothing was holding the
  # PVCs in the first place).
  local pods_drained=1

  local platforma_deploys
  platforma_deploys=$(kubectl --context "${ctx}" get deployment \
    -n "${PLATFORMA_NAMESPACE}" \
    -l app.kubernetes.io/name=platforma \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)

  if [[ -n "${platforma_deploys}" ]]; then
    info "Scaling platforma Deployment(s) to 0 (releases PVC mounts): $(echo "${platforma_deploys}" | tr '\n' ' ')"
    kubectl --context "${ctx}" scale deployment \
      -n "${PLATFORMA_NAMESPACE}" \
      -l app.kubernetes.io/name=platforma \
      --replicas=0
    info "Waiting for platforma pods to terminate (graceful shutdown ~30-60s)…"
    if ! kubectl --context "${ctx}" wait \
           -l app.kubernetes.io/name=platforma \
           -n "${PLATFORMA_NAMESPACE}" \
           --for=delete pod --timeout=180s 2>/dev/null; then
      pods_drained=0
      warn "platforma pods didn't terminate within 3 min."
      warn "  → PVC delete may stick on pvc-protection finalizer."
      warn "  → Force-clear will be REFUSED to avoid data corruption on still-running pods."
    fi
  else
    info "No platforma Deployment in ${PLATFORMA_NAMESPACE} — pods can't be holding the PVCs."
  fi

  local pvcs
  pvcs=$(kubectl --context "${ctx}" get pvc -n "${PLATFORMA_NAMESPACE}" \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)

  if [[ -z "${pvcs}" ]]; then
    info "No PVCs in ${PLATFORMA_NAMESPACE} namespace — nothing to clean."
    echo
    return 0
  fi

  info "Found PVCs: $(echo "${pvcs}" | tr '\n' ' ')"
  info "Deleting (kubernetes.io/pvc-protection finalizers will clear automatically — no pods are using them)…"

  # --wait=false because we'll poll below; gives uniform behavior even when
  # finalizers take longer than the default kubectl wait timeout.
  echo "${pvcs}" | xargs -I{} kubectl --context "${ctx}" delete pvc {} \
    -n "${PLATFORMA_NAMESPACE}" --wait=false --ignore-not-found 2>/dev/null

  # Poll for natural finalizer clearance (typical: 5-30s).
  local remaining
  for i in $(seq 1 24); do
    remaining=$(kubectl --context "${ctx}" get pvc -n "${PLATFORMA_NAMESPACE}" \
      --no-headers -o custom-columns=":metadata.name" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${remaining}" == "0" ]]; then
      info "All PVCs cleared."
      echo
      return 0
    fi
    info "  ${remaining} PVCs still terminating, sleeping 5s (${i}/24)…"
    sleep 5
  done

  # Force-clear safety guard: only patch finalizers=null when we know the
  # chart's pods drained cleanly. Otherwise removing pvc-protection on a
  # still-mounted PVC drops the volume out from under a running pod and
  # risks data corruption (database PVC has reclaim=Delete → underlying
  # PD-SSD gets garbage-collected on PVC delete). Operator gets a clear
  # recovery path instead.
  if (( pods_drained == 0 )); then
    red "PVCs still bound after 2 min, AND platforma pods did not terminate cleanly earlier."
    red "  → Refusing to force-remove finalizers — risk of data corruption on still-running pods."
    red "  → Manual recovery:"
    red "      kubectl get pods -n ${PLATFORMA_NAMESPACE} -l app.kubernetes.io/name=platforma"
    red "      kubectl delete pod <pod-name> -n ${PLATFORMA_NAMESPACE} --force --grace-period=0"
    red "      bash $0      # re-run this script"
    exit 1
  fi

  # Pods drained (or never existed) — finalizers are stuck for unrelated
  # reasons (rare; CSI driver lost track of the volume etc.). Safe to
  # force-clear.
  warn "PVCs still present after 2 min — force-removing finalizers (pods are gone)."
  kubectl --context "${ctx}" get pvc -n "${PLATFORMA_NAMESPACE}" \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | \
    xargs -I{} kubectl --context "${ctx}" patch pvc {} \
      -n "${PLATFORMA_NAMESPACE}" \
      -p '{"metadata":{"finalizers":null}}' --type=merge

  # And again, briefly, in case the API needed a moment.
  sleep 5
  remaining=$(kubectl --context "${ctx}" get pvc -n "${PLATFORMA_NAMESPACE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${remaining}" != "0" ]]; then
    warn "${remaining} PVCs still present after force-clear. Proceeding to IM destroy anyway — terraform will surface any remaining issue."
  fi
  echo
}

# -----------------------------------------------------------------------------
# Submit IM delete
# -----------------------------------------------------------------------------

# submit_im_delete <deployment_name>
# Idempotent: returns silently if the deployment doesn't exist. Called
# twice from main() — first for the platforma deployment, then for infra,
# so the GKE Gateway controller releases its GFE-side resources (target
# proxies, backend services, NEGs) before the certmap they reference is
# destroyed by the infra deployment.
submit_im_delete() {
  local deployment_name="$1"
  bold "Submitting IM destroy for ${deployment_name}"

  # describe stdout = state; stderr captured separately so we can distinguish
  # 'deployment does not exist' (404) from transient API errors that we
  # shouldn't silently treat as "nothing to delete".
  local state stderr_out
  stderr_out="$(mktemp)"
  state="$(gcloud infra-manager deployments describe "${deployment_name}" \
    --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
    --format="value(state)" 2>"${stderr_out}")" || state=""

  if [[ -z "${state}" ]]; then
    if grep -qE "(NOT_FOUND|was not found|does not exist)" "${stderr_out}"; then
      info "IM deployment ${deployment_name} not found in ${IM_LOCATION}. Nothing to delete."
      rm -f "${stderr_out}"
      return 0
    fi
    red "Failed to describe IM deployment ${deployment_name}:"
    sed 's/^/  /' "${stderr_out}" >&2
    rm -f "${stderr_out}"
    red "  → Retry once the underlying issue is fixed; the deployment is unchanged."
    exit 1
  fi
  rm -f "${stderr_out}"

  # Idempotency: a previous teardown that was Ctrl-C'd leaves the IM
  # deployment in DELETING. We must NOT just return — main() would then
  # submit the infra delete immediately, racing the still-running
  # platforma delete and triggering the certmap-in-use race that
  # null_resource.wait_gateway_gfe_cleanup is meant to prevent. Block
  # until the LRO actually finishes.
  case "${state}" in
    DELETING)
      info "Already DELETING — waiting for server-side completion."
      while :; do
        local s
        s="$(gcloud infra-manager deployments describe "${deployment_name}" \
              --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
              --format='value(state)' 2>/dev/null || echo GONE)"
        case "${s}" in
          DELETED|GONE) info "${deployment_name} deleted."; return 0 ;;
          FAILED)       red "${deployment_name} delete FAILED."; exit 1 ;;
        esac
        sleep 15
      done
      ;;
    DELETED)
      info "Already DELETED."
      return 0
      ;;
  esac

  info "Current state: ${state}. Submitting delete…"
  echo
  cat <<EOF
  Monitoring URLs (open in browser if this terminal disconnects):
    - Infrastructure Manager:   https://console.cloud.google.com/infra-manager/deployments?project=${PROJECT_ID}
    - Cloud Build (TF destroy): https://console.cloud.google.com/cloud-build/builds;region=${IM_LOCATION}?project=${PROJECT_ID}

  This call blocks for ~10 min on a healthy delete. If Cloud Shell
  disconnects, the destroy continues server-side; re-run this script
  (it's idempotent) or check the URLs above to see the outcome.

EOF
  gcloud infra-manager deployments delete "${deployment_name}" \
    --location="${IM_LOCATION}" \
    --project="${PROJECT_ID}" \
    --delete-policy=delete \
    --quiet
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  bold "Platforma on GCP — teardown"
  echo

  resolve_inputs

  # Two-stage deployment names — must match install.sh's main().
  local infra_deployment="${DEPLOYMENT_NAME}-infra"
  local platforma_deployment="${DEPLOYMENT_NAME}-platforma"

  cat <<EOF
This will:
  1. Delete all PVCs in the '${PLATFORMA_NAMESPACE}' namespace of cluster
     '${CLUSTER_NAME}' (workspace, database, logs — annotated 'keep' by the
     chart, retained on helm uninstall, but in the way of a full teardown).
  2. Submit 'gcloud infra-manager deployments delete ${platforma_deployment}'
     with --delete-policy=delete (destroys Kueue/AppWrapper/Platforma chart/
     Gateway). The Gateway controller releases its GFE child resources
     during this destroy — must complete before the infra deployment's
     certmap is destroyed.
  3. Submit 'gcloud infra-manager deployments delete ${infra_deployment}'
     with --delete-policy=delete (destroys GKE cluster, Filestore, GCS,
     network, IAM, certmap, DNS).

Everything terraform manages goes away: GKE cluster, Filestore (workspace
data), GCS primary bucket (only if applied with GCS_FORCE_DESTROY=true,
otherwise empty it manually first), VPC + Cloud NAT, IAM, certs, DNS A
record. The Cloud DNS managed zone and any pre-existing storage outside
terraform state are left untouched.

EOF
  require_phrase "delete ${DEPLOYMENT_NAME} from ${PROJECT_ID}"

  cleanup_pvcs

  # Platforma first — releases the K8s Gateway and lets the GKE Gateway
  # controller clean up its GFE-side resources (target-https-proxy,
  # backend-services, NEGs) before the certmap they reference is destroyed.
  submit_im_delete "${platforma_deployment}"

  # Then infra — certmap, cluster, network, GCS, etc.
  submit_im_delete "${infra_deployment}"

  bold "Teardown complete"
}

main "$@"
