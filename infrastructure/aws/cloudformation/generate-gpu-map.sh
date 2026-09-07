#!/usr/bin/env bash
#
# generate-gpu-map.sh — build the static AWS region -> GPU-pool map used by
# cloudformation-eks-1-35.yaml.
#
# MODEL
#   Each GPU node group ("pool") corresponds to a REAL GPU card offered in the
#   region, and its gpu-memory-gib label equals that card's actual per-GPU VRAM.
#   A region gets only the pools whose card it actually offers — no fallback
#   substitution, so a label never lies and hardware is never under-used. If a
#   region offers nothing but T4 (g4dn), it gets a single 16g pool as a last
#   resort; where anything better exists, T4 is not offered as a pool.
#
#   Pool     Card / family        Label  Instance
#   gpu-3g   L4 fractional (g6f)  3      g6f.xlarge     } created where g6f
#   gpu-6g   L4 fractional (g6f)  6      g6f.2xlarge    } is offered
#   gpu-12g  L4 fractional (g6f)  12     g6f.4xlarge    }
#   gpu-24g  L4 / A10G            24     g6.2xlarge or g5.2xlarge (g6 preferred)
#   gpu-48g  L40S (g6e)           48     g6e.2xlarge    } created where g6e
#   gpu-96g  4x L40S (g6e)        48     g6e.12xlarge   } is offered
#   gpu-16g  T4 (g4dn)            16     g4dn.2xlarge   fallback: only when a
#                                                       region has no g6f/24g/g6e
#
# OUTPUTS
#   1. gpu-instance-map.json — committed, human-auditable: region -> pool ->
#      {type, azIds}. AZ IDs (euw2-az1) are account-stable, unlike AZ names.
#   2. Injects into cloudformation-eks-1-35.yaml (via generate-gpu-map.py):
#        - the map into the GpuSubnetResolver Lambda (subnet/type resolution), and
#        - the GpuRegionCoverage Mapping (region -> per-GPU-class yes/no); the
#          static RegionHas* Conditions Fn::FindInMap it to gate each node group.
#
# USAGE
#   ./generate-gpu-map.sh                 # query all enabled regions, write + inject
#   ./generate-gpu-map.sh --regions "eu-west-1 us-east-1"
#   ./generate-gpu-map.sh --no-inject     # only write gpu-instance-map.json
#
# Requires awscli v2 (ec2:DescribeRegions + ec2:DescribeInstanceTypeOfferings),
# jq, python3. Regions absent from the map (opt-in regions not enabled in the
# generating account) get no GPU pools until the map is regenerated there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${SCRIPT_DIR}/gpu-instance-map.json"
TEMPLATE_FILE="${SCRIPT_DIR}/cloudformation-eks-1-35.yaml"
REGIONS_ARG=""
DO_INJECT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --regions) REGIONS_ARG="$2"; shift 2 ;;
    --no-inject) DO_INJECT=0; shift ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for bin in aws jq python3; do
  command -v "$bin" >/dev/null || { echo "ERROR: '$bin' not found" >&2; exit 1; }
done
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}" AWS_RETRY_MODE="${AWS_RETRY_MODE:-adaptive}"

# Marker instance types probed per region (one per pool candidate).
MARKERS="g6f.xlarge,g6f.2xlarge,g6f.4xlarge,g4dn.2xlarge,g5.2xlarge,g6.2xlarge,g6e.2xlarge,g6e.12xlarge"

if [[ -n "$REGIONS_ARG" ]]; then
  REGIONS="$REGIONS_ARG"
else
  echo "Discovering enabled regions..." >&2
  REGIONS="$(aws ec2 describe-regions \
    --query 'Regions[?OptInStatus!=`not-opted-in`].RegionName' \
    --output text | tr '\t' '\n' | sort | tr '\n' ' ')"
fi
echo "Regions: $REGIONS" >&2

RAW="$(mktemp)"
ALL_REGIONS_FILE="$(mktemp)"
trap 'rm -f "$RAW" "$ALL_REGIONS_FILE"' EXIT

# Every AWS region (incl. not-opted-in) so the injected GpuRegionCoverage Mapping
# has an entry for all of them — the template's Fn::FindInMap lookups then never
# miss and need no default value (which would require AWS::LanguageExtensions).
aws ec2 describe-regions --all-regions --query 'Regions[].RegionName' --output text 2>/dev/null \
  | tr '\t' '\n' | sort > "$ALL_REGIONS_FILE"

for region in $REGIONS; do
  echo "  querying $region ..." >&2
  aws ec2 describe-instance-type-offerings --region "$region" \
      --location-type availability-zone-id \
      --filters "Name=instance-type,Values=${MARKERS}" \
      --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output text 2>/dev/null \
    | jq -R -s --arg r "$region" \
        'split("\n")|map(select(length>0)|split("\t"))
         |reduce .[] as $x ({}; .[$x[0]] += [$x[1]])
         |{region:$r, offerings: (.|map_values(sort))}' -c
done > "$RAW"

python3 "${SCRIPT_DIR}/generate-gpu-map.py" "$RAW" "$ALL_REGIONS_FILE" "$OUT_FILE" "$TEMPLATE_FILE" "$DO_INJECT"

echo "Done." >&2
