# Upgrade Guide: ProvisioningRequest on GKE

Starting with Platforma Helm chart v3.2.2, the chart creates ProvisioningRequest admission checks that prevent Kueue resource fragmentation.

## GKE vs AWS

GKE has **native ProvisioningRequest support** — the CRD is pre-installed and the built-in cluster autoscaler handles it automatically. No separate CRD install, no Cluster Autoscaler flags, no RBAC grants needed.

| Component | AWS EKS | GKE |
|-----------|---------|-----|
| ProvisioningRequest CRD | Manual install required | Pre-installed |
| Cluster Autoscaler flags | `--enable-provisioning-requests`, `--kube-api-content-type` | Not needed (built-in) |
| CA RBAC | Manual ClusterRole + Binding | Not needed |
| Kueue `ProvisioningACC` | Must enable | Must enable |
| Kueue memory bump | Recommended (512Mi → 1Gi) | Recommended |
| Chart `provisioningRequest.enabled` | Must set | Must set |

## Prerequisites

Verify the CRD exists (should be pre-installed on GKE 1.29+):

```bash
kubectl get crd provisioningrequests.autoscaling.x-k8s.io
```

If missing, your GKE version may not support it. Check your cluster version:

```bash
kubectl version --short
```

ProvisioningRequest requires GKE 1.29 or later.

## Step 1: Upgrade Kueue

Add `ProvisioningACC` feature gate and bump memory limits:

```bash
helm upgrade kueue oci://registry.k8s.io/kueue/charts/kueue \
  -n <kueue-namespace> --reuse-values \
  --set controllerManager.manager.resources.limits.memory=1Gi \
  --set controllerManager.manager.resources.requests.memory=512Mi \
  --set featureGates.ProvisioningACC=true
```

Verify the provisioning controller started:

```bash
kubectl logs -n <kueue-namespace> -l control-plane=controller-manager --tail=20 | grep -i provision
# Should see: "Caches populated" for ProvisioningRequestConfig and ProvisioningRequest
```

If you see `Skipping provisioning controller setup`, the CRD wasn't found at Kueue startup. Restart Kueue:

```bash
kubectl rollout restart deployment kueue-controller-manager -n <kueue-namespace>
```

## Step 2: Upgrade Platforma Chart

Add `provisioningRequest.enabled: true` to your values file:

```yaml
kueue:
  provisioningRequest:
    enabled: true
```

Then upgrade:

```bash
helm upgrade platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.2.2 \
  -n <namespace> \
  -f values.yaml \
  --atomic --timeout 15m
```

Or with `--reuse-values`:

```bash
helm upgrade platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.2.2 \
  -n <namespace> --reuse-values \
  --set kueue.provisioningRequest.enabled=true
```

## Verification

```bash
# 1. AdmissionCheck is Active
kubectl get admissionchecks
# Should show: platforma-provreq (or <release>-platforma-provreq)

# 2. ProvisioningRequestConfig exists
kubectl get provisioningrequestconfig
# Should show: platforma-provreq-config

# 3. Batch ClusterQueue references the AdmissionCheck
kubectl get clusterqueue <release>-platforma-batch -o yaml | grep -A3 admissionChecksStrategy
# Should show: platforma-provreq

# 4. Kueue provisioning controller is active
kubectl logs -n <kueue-namespace> -l control-plane=controller-manager --tail=20 | grep provision
```

## Clusters Without Node Autoscaling

If your GKE cluster has fixed-size node pools (no autoscaling), disable ProvisioningRequest:

```yaml
kueue:
  provisioningRequest:
    enabled: false
```

Without an autoscaler responding to ProvisioningRequests, the AdmissionCheck stays Inactive and blocks all batch job admissions.

## Troubleshooting

### AdmissionCheck Inactive

```
Can't admit new workloads: references inactive AdmissionCheck(s): platforma-provreq
```

**Cause:** Kueue's provisioning controller didn't start — CRD was missing when Kueue first started.

**Fix:** Verify the CRD exists, then restart Kueue:

```bash
kubectl get crd provisioningrequests.autoscaling.x-k8s.io
kubectl rollout restart deployment kueue-controller-manager -n <kueue-namespace>
```

### Kueue OOMKilled

**Cause:** Too many completed AppWrappers accumulating.

**Fix:** Increase Kueue memory limit to at least 1Gi and clean up stale AppWrappers:

```bash
kubectl get appwrappers -n <namespace> --no-headers -o name | \
  xargs -n 100 kubectl delete -n <namespace> --wait=false
```
