# ProvisioningRequest Test Results

Tested on `platforma-cluster-lab` (EKS, eu-west-1) on 2026-04-14 and 2026-04-16.

## Setup

- EKS 1.35, Kueue v0.16.1, AppWrapper v1.2.0
- Cluster Autoscaler v1.35.0 (chart 9.56.0) with:
  - `--enable-provisioning-requests=true`
  - `--kube-api-content-type=application/json`
  - Supplementary RBAC for `provisioningrequests`, `/status`, `podtemplates`
- ProvisioningRequest CRD installed from `cluster-autoscaler-1.35.0` tag
- Provisioning class: `best-effort-atomic-scale-up.autoscaling.x-k8s.io`
- AdmissionCheck on batch ClusterQueue only (not UI)
- Batch node groups: `m7i.4xlarge` (16 vCPU / 64 GiB), scale-from-zero

## Test 1: Scale-From-Zero

**Scenario:** Zero batch nodes, submit a 1 GiB job.

**Result:** Kueue created ProvisioningRequest → CA responded `Accepted=True, Provisioned=True` → workload admitted → CA scaled up batch node → job ran and completed.

**Verdict:** PASS. `best-effort-atomic-scale-up` handles scale-from-zero correctly.

## Test 2: Resource Fragmentation

**Scenario:** 4 batch nodes each running a 48 GiB filler (~10 GiB free per node, ~40 GiB aggregate free). Submit a 30 GiB victim job.

**Without ProvisioningRequest:** Kueue admitted the job (30 GiB < 40 GiB aggregate). Pod got `FailedScheduling: 2 Insufficient memory`. CA triggered an unnecessary 3rd node scale-up. If the cluster had been at max nodes, the job would have timed out after AppWrapper's 30-minute `warmupGracePeriodDuration`.

**With ProvisioningRequest:** CA responded `Provisioned=True (CapacityIsProvisioned)` — it provisioned a new node for the victim instead of admitting onto fragmented capacity. Job ran successfully on the new node.

**Verdict:** PASS. Fragmentation is handled correctly — CA provisions a fresh node rather than letting Kueue admit a job that can't schedule.

## Test 3: Pool at Capacity (Quota Exhausted)

**Scenario:** Batch queue quota temporarily reduced to 4 CPU / 96 GiB. A filler job (3 CPU / 80 GiB) uses most of the quota. A victim job (2 CPU / 20 GiB) is submitted — exceeds remaining quota. AppWrapper `warmupGracePeriodDuration` set to 2 minutes to verify no premature timeout.

| Time | Event |
|------|-------|
| T+0s | Filler admitted, running. Victim submitted. |
| T+7s | Victim stays `Suspended` — Kueue holds it (quota insufficient). |
| T+2m | Past AppWrapper's 2-minute timeout — victim still `Suspended`, no error. |
| T+8m | Victim still `Suspended` — no timeout triggered. |
| T+10m | Filler completes (`Succeeded`). Quota freed. |
| T+10m+9s | Kueue automatically admits victim → ProvisioningRequest `Provisioned=True`. |
| T+11m | Victim runs on existing batch node and completes (`Succeeded`). |

**Verdict:** PASS. When Kueue holds a workload due to insufficient quota:
- AppWrapper stays `Suspended` indefinitely — the `warmupGracePeriodDuration` timer does NOT start until the workload is admitted
- Once quota frees up, Kueue automatically admits the waiting workload
- The entire queue → admit → run cycle is automatic with no manual intervention

## Test 4: Provisioning Class Comparison

| Class | Scale-from-zero | Steady-state fragmentation | Behavior |
|-------|----------------|---------------------------|----------|
| `best-effort-atomic-scale-up.autoscaling.x-k8s.io` | PASS — provisions node | PASS — provisions fresh node | Recommended |
| `check-capacity.autoscaling.x-k8s.io` | Responds `CapacityIsNotFound`, no scale-up — workload stays queued forever | Should work (checks per-node fit) | Not suitable for scale-from-zero |

## Key Findings

1. **AppWrapper timeout is safe.** The `warmupGracePeriodDuration` only starts counting after Kueue admits the workload and AppWrapper creates inner resources. While the workload is held in Kueue's queue (`Suspended`), no timer runs.

2. **Kueue queue-to-admit is automatic.** When capacity becomes available (quota freed, nodes available), Kueue re-evaluates pending workloads and admits them without manual intervention.

3. **ProvisioningRequest prevents fragmented admission.** Without it, Kueue admits based on aggregate capacity. With it, CA checks per-node fit and provisions a suitable node if needed.

4. **Three CA configuration gotchas:**
   - Class names must be FQDN (`best-effort-atomic-scale-up.autoscaling.x-k8s.io`, not `best-effort-atomic`)
   - `--kube-api-content-type=application/json` required (CA bug [#8855](https://github.com/kubernetes/autoscaler/issues/8855))
   - Supplementary RBAC needed for `provisioningrequests`, `/status`, `podtemplates`

## Infrastructure Requirements

For ProvisioningRequest to work, the following must be in place:

1. ProvisioningRequest CRD (installed before Kueue starts)
2. Cluster Autoscaler with `--enable-provisioning-requests=true` and `--kube-api-content-type=application/json`
3. CA RBAC for `provisioningrequests`, `provisioningrequests/status`, `podtemplates`
4. Kueue with `ProvisioningACC` feature gate (enabled by default in v0.10+)

All handled automatically by the CloudFormation template.
