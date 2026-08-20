#!/usr/bin/env bash
# GPU SKU zone discovery + stock probe.
#
# Two modes:
#
#   discover  — invoked by cloudshell/install.sh before submitting the IM
#     deployment. Cannot run inside Terraform because IM's tf-runner image
#     ships without gcloud; install.sh runs it in Cloud Shell, captures the
#     per-shape zone map, and embeds it into the IM input document as the
#     gpu_l4_pools / gpu_rtx_pro_6000_pools tfvars.
#     Input (JSON via stdin):
#       {"project": "...", "region": "...", "sku": "nvidia-l4|nvidia-rtx-pro-6000"}
#     Output (JSON via stdout):
#       {"pools": {"g2-standard-4": ["zone-a","zone-b"], "g2-standard-8": ["zone-a"], ...}}
#     For each shape in the SKU's ladder, lists the zones in <region> that
#     offer it; a shape offered in no zone is omitted (adaptive ladder — a
#     region provisions only the shapes it actually has). The ladders are
#     hardcoded below and MUST stay in sync with the fallback defaults in
#     gke.tf. Exits non-zero only if the accelerator type is offered in NO
#     zone of the region (install.sh then skips that SKU entirely); otherwise
#     exits 0, possibly with a partial (or empty) pool map.
#
#   probe [l4|rtx|both]  — interactive stock check (operator tool, not
#     called by install.sh). For each SKU, sweeps every zone in GCP where
#     the accelerator type exists and tries to create one VM with the
#     smallest single-GPU shape. Classifies the result:
#       AVAILABLE    — instance created (deleted immediately after)
#       EXHAUSTED    — ZONE_RESOURCE_POOL_EXHAUSTED (genuine inventory stockout)
#       QUOTA        — quota wall (won't be fixed by switching zone)
#       OTHER:<line> — anything else, printed verbatim
#
# Usage:
#   install-time discovery: (auto — called by cloudshell/install.sh)
#   human stock probe:      PROJECT_ID=your-gcp-project ./gcptest.sh probe [l4|rtx|both]
#   debug discovery:        echo '{"project":"P","region":"R","sku":"S"}' | ./gcptest.sh discover

set -uo pipefail

# =============================================================================
# Ladders — MUST mirror gke.tf's local.gpu_l4_pools / gpu_rtx_pro_6000_pools.
# =============================================================================
L4_LADDER=(g2-standard-4 g2-standard-8 g2-standard-12 g2-standard-16 g2-standard-32)
RTX_LADDER=(g4-standard-6 g4-standard-12 g4-standard-24 g4-standard-48)

# Smallest single-GPU shape per SKU — used by the probe mode (sufficient to
# tell whether the zone has *any* GPU stock; bigger sizes follow the same
# inventory pool).
L4_PROBE_SHAPE=g2-standard-4
RTX_PROBE_SHAPE=g4-standard-6

# =============================================================================
# discover — terraform external data source
# =============================================================================
mode_discover() {
  local input project region sku
  input=$(cat)
  project=$(printf '%s' "$input" | jq -r '.project // ""')
  region=$(printf '%s'  "$input" | jq -r '.region  // ""')
  sku=$(printf '%s'     "$input" | jq -r '.sku     // ""')

  if [[ -z "$project" || -z "$region" || -z "$sku" ]]; then
    echo "discover: missing required input(s); got project='${project}' region='${region}' sku='${sku}'" >&2
    exit 1
  fi

  local ladder
  case "$sku" in
    nvidia-l4)            ladder=("${L4_LADDER[@]}") ;;
    nvidia-rtx-pro-6000)  ladder=("${RTX_LADDER[@]}") ;;
    *) echo "discover: unknown sku '${sku}'; expected nvidia-l4 or nvidia-rtx-pro-6000" >&2; exit 1 ;;
  esac

  # All zones in the region where this accelerator type is offered.
  local sku_zones
  sku_zones=$(gcloud compute accelerator-types list \
                --project="$project" \
                --format='value(name,zone)' 2>/dev/null \
              | awk -v sku="$sku" -v region="$region" \
                  '$1==sku && index($2, region"-")==1 {print $2}' \
              | sort -u)

  if [[ -z "$sku_zones" ]]; then
    echo "discover: accelerator type '${sku}' is not offered in any zone of region '${region}'." >&2
    echo "         Possible regions for this SKU (run from a shell):" >&2
    echo "         gcloud compute accelerator-types list --project=${project} --filter='name=${sku}' --format='value(zone)' | sed 's/-[a-z]\$//' | sort -u" >&2
    exit 1
  fi

  # Adaptive ladder: for each shape, collect the zones (among sku_zones) that
  # offer it. A shape offered in no zone is simply omitted — the region gets a
  # pool for every shape it actually has, instead of all-or-nothing.
  local pools='{}'
  local zone zone_shapes shape
  for zone in $sku_zones; do
    zone_shapes=$(gcloud compute machine-types list \
                    --project="$project" --zones="$zone" \
                    --format='value(name)' 2>/dev/null | sort -u)
    for shape in "${ladder[@]}"; do
      if grep -qFx "$shape" <<<"$zone_shapes"; then
        pools=$(jq --arg s "$shape" --arg z "$zone" \
                  '.[$s] = (((.[$s] // []) + [$z]) | unique)' <<<"$pools")
      fi
    done
  done

  # {pools:{shape:[zones]}} — possibly empty if the accelerator is offered but
  # (unexpectedly) none of the ladder shapes are. install.sh skips a SKU whose
  # pool map is empty.
  jq -cn --argjson pools "$pools" '{pools: $pools}'
}

# =============================================================================
# probe — interactive stock check (preserved from previous gcptest.sh)
# =============================================================================
PROBE_PREFIX=gpu-stock-probe

probe_one() {
  local zone=$1 sku=$2 shape=$3
  local project=${PROJECT_ID}
  local name="${PROBE_PREFIX}-$(printf '%s' "$sku" | tr '_' '-')-$$-$RANDOM"
  local errf="${PROBE_DIR}/${zone}-${sku}.err"
  local result

  if gcloud compute instances create "$name" \
       --project="$project" --zone="$zone" \
       --machine-type="$shape" \
       --accelerator="type=${sku},count=1" \
       --image-family=debian-12 --image-project=debian-cloud \
       --boot-disk-size=20GB --no-address \
       --maintenance-policy=TERMINATE >/dev/null 2>"$errf"; then
    result=AVAILABLE
    gcloud compute instances delete "$name" \
      --project="$project" --zone="$zone" --quiet >/dev/null 2>&1 &
  else
    if   grep -q 'ZONE_RESOURCE_POOL_EXHAUSTED' "$errf"; then result=EXHAUSTED
    elif grep -q "Quota '" "$errf"; then
      result="QUOTA: $(grep -o "Quota '[^']*' exceeded" "$errf" | head -1)"
    else
      result="OTHER: $(grep -iE 'error|denied|not found' "$errf" | head -1 | tr -s ' ' | cut -c1-120)"
    fi
  fi
  printf '%-22s %-25s %-18s %s\n' "$zone" "$sku" "$shape" "$result"
}
export -f probe_one
export PROBE_PREFIX

probe_run_sku() {
  local sku=$1 shape=$2
  local zones; zones=$(gcloud compute accelerator-types list \
                         --project="$PROJECT_ID" \
                         --filter="name=${sku}" \
                         --format='value(zone)' 2>/dev/null | sort -u)
  local count; count=$(printf '%s\n' "$zones" | wc -l | tr -d ' ')
  echo
  echo "=== ${sku} (${shape}) — probing ${count} zones in parallel ==="
  printf '%-22s %-25s %-18s %s\n' ZONE SKU SHAPE RESULT
  printf '%.0s-' {1..100}; echo
  export PROBE_DIR PROJECT_ID
  for z in $zones; do
    probe_one "$z" "$sku" "$shape" &
  done
  wait
}

mode_probe() {
  if [[ -z "${PROJECT_ID:-}" ]]; then
    echo "probe: PROJECT_ID env var is required" >&2
    echo "       PROJECT_ID=your-gcp-project ./gcptest.sh probe [l4|rtx|both]" >&2
    exit 1
  fi
  PROBE_DIR=$(mktemp -d -t gpu-probe-XXXX)
  trap 'rm -rf "$PROBE_DIR"' EXIT

  local which=${1:-both}
  case "$which" in
    l4)   probe_run_sku nvidia-l4           "$L4_PROBE_SHAPE" ;;
    rtx)  probe_run_sku nvidia-rtx-pro-6000 "$RTX_PROBE_SHAPE" ;;
    both) probe_run_sku nvidia-l4           "$L4_PROBE_SHAPE"
          probe_run_sku nvidia-rtx-pro-6000 "$RTX_PROBE_SHAPE" ;;
    *) echo "Usage: $0 probe [l4|rtx|both]" >&2; exit 1 ;;
  esac
  wait
  echo
  echo "[done] If interrupted, leaked VMs are named ${PROBE_PREFIX}-* — list with:"
  echo "       gcloud compute instances list --project=${PROJECT_ID} --filter='name~^${PROBE_PREFIX}-'"
}

# =============================================================================
# entry
# =============================================================================
case "${1:-}" in
  discover) mode_discover ;;
  probe)    shift; mode_probe "${1:-both}" ;;
  *) cat <<EOF >&2
Usage:
  $0 discover                     (called by terraform — reads JSON from stdin)
  $0 probe [l4|rtx|both]          (interactive stock check across all zones)
EOF
     exit 1 ;;
esac
