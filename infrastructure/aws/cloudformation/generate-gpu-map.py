#!/usr/bin/env python3
"""Build the static AWS region -> GPU-pool map and inject it into the
CloudFormation template. Invoked by generate-gpu-map.sh (which gathers the raw
EC2 offerings); kept as a separate file for readability.

Args: <raw_offerings.jsonl> <all_regions.txt> <gpu-instance-map.json> <template.yaml> <do_inject:0|1>

Produces:
  * gpu-instance-map.json — committed, human-auditable: region -> {pools, gpuMax}.
  * (when do_inject) injects into the template:
      - STATIC_MAP into the GpuSubnetResolver Lambda, and
      - the GpuRegionCoverage Mapping (region -> per-GPU-class yes/no) that the
        static RegionHas* Conditions look up via Fn::FindInMap.
"""
import json
import re
import sys

raw_path, all_regions_path, out_path, tpl_path = sys.argv[1:5]
do_inject = sys.argv[5] == "1"

# Pool label = real per-GPU VRAM (GiB). Fixed per pool because a pool is only
# created where its native card is offered.
POOL_MEM = {"gpu-3g": 3, "gpu-6g": 6, "gpu-12g": 12, "gpu-16g": 16,
            "gpu-24g": 24, "gpu-48g": 48, "gpu-96g": 48}

# vCPU / RAM (GiB) per instance type, used to compute the per-region GPU job
# ceilings (gpuMax). Verified from ec2 describe-instance-types.
SPECS = {
    "g6f.xlarge": (4, 16), "g6f.2xlarge": (8, 32), "g6f.4xlarge": (16, 64),
    "g4dn.2xlarge": (8, 32), "g5.2xlarge": (8, 32), "g6.2xlarge": (8, 32),
    "g6e.2xlarge": (8, 64), "g6e.12xlarge": (48, 384),
}
# CPU headroom (cores) reserved on a GPU node for system + nvidia DaemonSets;
# the CPU ceiling is node vCPU minus this so ceiled jobs still fit.
CPU_HEADROOM = 2

# GpuRegionCoverage second-level key -> the pool whose presence sets it to "yes".
# The static RegionHas* Conditions in the template look these up per region.
COVERAGE_KEYS = {"G6f": "gpu-3g", "C24g": "gpu-24g", "G6e": "gpu-48g", "T4": "gpu-16g"}


def build_pools(off):
    """off: {instance_type: [azId,...]} -> {pool: {type, azIds, memGib}}."""
    pools = {}
    if "g6f.xlarge" in off:   pools["gpu-3g"] = ("g6f.xlarge", off["g6f.xlarge"])
    if "g6f.2xlarge" in off:  pools["gpu-6g"] = ("g6f.2xlarge", off["g6f.2xlarge"])
    if "g6f.4xlarge" in off:  pools["gpu-12g"] = ("g6f.4xlarge", off["g6f.4xlarge"])
    # 24g: prefer L4 (g6), else A10G (g5) — both are 24 GiB single-GPU.
    if "g6.2xlarge" in off:    pools["gpu-24g"] = ("g6.2xlarge", off["g6.2xlarge"])
    elif "g5.2xlarge" in off:  pools["gpu-24g"] = ("g5.2xlarge", off["g5.2xlarge"])
    if "g6e.2xlarge" in off:   pools["gpu-48g"] = ("g6e.2xlarge", off["g6e.2xlarge"])
    if "g6e.12xlarge" in off:  pools["gpu-96g"] = ("g6e.12xlarge", off["g6e.12xlarge"])
    # T4 fallback: only when nothing better is available in the region.
    if not pools and "g4dn.2xlarge" in off:
        pools["gpu-16g"] = ("g4dn.2xlarge", off["g4dn.2xlarge"])
    return {p: {"type": t, "azIds": az, "memGib": POOL_MEM[p]} for p, (t, az) in pools.items()}


def gpu_max(pools):
    """Per-region GPU job ceilings, taken from ONE real node: the pool with the
    most VRAM (tie-break: most CPU). Fed to the backend's
    --k8s-gpu-max-{cpu,ram}-request and kueue gpuMemory.

    GPU jobs are placed by VRAM (node affinity on gpu-memory-gib), and the
    highest-VRAM jobs can run ONLY on this node — so the cpu/ram caps must be
    <= its specs or those jobs stay Pending. Mixing per-dimension maxima would
    advertise an envelope (e.g. 16 vCPU + 24 GiB VRAM) that no single node
    provides, so a task at that corner never schedules. Basing it on the max-CPU
    node instead would cap VRAM below the biggest card and waste it."""
    top = max(pools.values(), key=lambda p: (p["memGib"], SPECS[p["type"]][0]))
    cpu, ram = SPECS[top["type"]]
    return {"cpu": cpu - CPU_HEADROOM, "ramGi": ram, "gpuGi": top["memGib"]}


def replace_between(src, begin, end, body):
    """Replace the text between (and preserving) the begin/end marker lines."""
    if begin not in src or end not in src:
        sys.exit(f"ERROR: markers not found in template: {begin}")
    indent = re.search(r'([ \t]*)' + re.escape(begin), src).group(1)
    block = f"{indent}{begin}\n{body}\n{indent}{end}"
    pattern = re.escape(indent) + re.escape(begin) + r".*?" + re.escape(end)
    out, n = re.subn(pattern, block, src, flags=re.DOTALL)
    assert n == 1, f"marker block count={n} for {begin}"
    return out, indent


regions = {}       # region -> {pool: {...}}  (covered regions only; for reporting)
regions_out = {}   # region -> {"pools": {...}, "gpuMax": {...}}  (serialized)
for line in open(raw_path):
    line = line.strip()
    if not line:
        continue
    rec = json.loads(line)
    pools = build_pools(rec["offerings"])
    if pools:
        regions[rec["region"]] = pools
        regions_out[rec["region"]] = {"pools": pools, "gpuMax": gpu_max(pools)}

out = {
    "description": ("AWS region -> {pools: pool -> instance type + offering AZ IDs; "
                    "gpuMax: per-region GPU job ceilings}. One pool per real GPU card "
                    "offered; label=real per-GPU VRAM; T4 (gpu-16g) only where nothing "
                    "better exists. Generated by generate-gpu-map.sh; do not hand-edit. "
                    "AZ IDs (euw2-az1) are account-stable, unlike AZ names."),
    "poolMemGib": POOL_MEM,
    "regions": dict(sorted(regions_out.items())),
}
with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")

# --- report ---
print(f"Wrote {out_path}: {len(regions)} regions with GPU pools", file=sys.stderr)
for r in sorted(regions):
    ps = regions[r]
    line = "  ".join(f"{p}={ps[p]['type']}" for p in POOL_MEM if p in ps)
    gm = regions_out[r]["gpuMax"]
    print(f"  {r:16} {line}   [gpuMax cpu={gm['cpu']} ram={gm['ramGi']}Gi gpu={gm['gpuGi']}Gi]",
          file=sys.stderr)

if not do_inject:
    sys.exit(0)

with open(tpl_path) as f:
    src = f.read()

# 1) Inject the static map into the Lambda (indented at the marker's own indent).
compact = json.dumps({"regions": out["regions"], "poolMemGib": POOL_MEM},
                     separators=(",", ":"), sort_keys=True)
map_begin = "# BEGIN GENERATED GPU MAP (generate-gpu-map.sh) — do not edit by hand"
mindent = re.search(r'([ \t]*)' + re.escape(map_begin), src).group(1)
src, _ = replace_between(
    src, map_begin, "# END GENERATED GPU MAP",
    f"{mindent}STATIC_MAP = json.loads(r'''{compact}''')")

# 2) Inject the GpuRegionCoverage Mapping (region -> per-GPU-class yes/no).
#    Covers ALL regions (from describe-regions --all-regions) so the template's
#    Fn::FindInMap lookups never miss — no default value / transform needed.
#    Regions the generator could not probe (e.g. not-opted-in) are all "no".
all_regions = sorted({r.strip() for r in open(all_regions_path) if r.strip()}
                     | set(regions_out))
cov_begin = "# BEGIN GENERATED GPU COVERAGE MAPPING (generate-gpu-map.sh) — do not edit by hand"
cov_end = "# END GENERATED GPU COVERAGE MAPPING"
cindent = re.search(r'([ \t]*)' + re.escape(cov_begin), src).group(1)
rows = [f"{cindent}GpuRegionCoverage:"]
for region in all_regions:
    have = regions.get(region, {})
    flags = " ".join(f'{k}: "{"yes" if pool in have else "no"}",' for k, pool in COVERAGE_KEYS.items()).rstrip(",")
    rows.append(f'{cindent}  {region}: {{{flags}}}')
src, _ = replace_between(src, cov_begin, cov_end, "\n".join(rows))

with open(tpl_path, "w") as f:
    f.write(src)

print(f"Injected static map + GpuRegionCoverage mapping ({len(all_regions)} regions).",
      file=sys.stderr)
for key, pool in COVERAGE_KEYS.items():
    covered = sorted(r for r, p in regions.items() if pool in p)
    print(f"  {key} (=yes): {', '.join(covered)}", file=sys.stderr)
