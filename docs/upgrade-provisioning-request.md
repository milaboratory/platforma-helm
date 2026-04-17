# Upgrade Guide: ProvisioningRequest Integration

Starting with Platforma Helm chart v3.2.2, the chart creates ProvisioningRequest admission checks that prevent Kueue resource fragmentation. This requires additional infrastructure components.

## What Changed

Kueue admits workloads based on aggregate cluster capacity, but Kubernetes scheduling requires per-node fit. Without ProvisioningRequest, a 30 GiB job gets admitted when 3 nodes each have 10 GiB free (30 GiB aggregate), but no single node can run it — causing AppWrapper timeouts or unnecessary node scale-ups.

The chart now creates:
- `ProvisioningRequestConfig` with class `best-effort-atomic-scale-up.autoscaling.x-k8s.io`
- `AdmissionCheck` referencing the config
- `admissionChecksStrategy` on the batch `ClusterQueue` (not UI — UI tasks are small)

## CloudFormation Deployments

Update the CF template and run a stack update. The template includes `ForceUpdateInfra` which triggers the HelmDeployer CodeBuild to install all prerequisites (CRD, CA flags, RBAC, Kueue memory) before the Platforma chart upgrade.

> **Important:** The HelmDeployer only re-runs when CloudFormation detects a property change on the `TriggerHelmDeploy` custom resource. The `ForceUpdateInfra` property exists specifically for this purpose — it is bumped in the template whenever infra sub-charts (Kueue, Cluster Autoscaler, External DNS, ALB Controller) need re-deployment. If you are upgrading from an older template and the HelmDeployer doesn't run, verify that `ForceUpdateInfra` has been incremented compared to the currently deployed template.

The rest of this guide is for reference and for manual (non-CF) deployments.

## Manual Deployments

The following must be in place **before** upgrading the Platforma chart. The order matters.

### 1. Install ProvisioningRequest CRD

The CRD is not bundled with any Helm chart. Install it matching your Cluster Autoscaler version:

```bash
CA_VERSION="1.35.0"  # Must match your Cluster Autoscaler image tag
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/kubernetes/autoscaler/cluster-autoscaler-${CA_VERSION}/cluster-autoscaler/apis/config/crd/autoscaling.x-k8s.io_provisioningrequests.yaml
```

Kueue checks for this CRD at startup. If it was installed after Kueue, restart Kueue:

```bash
kubectl rollout restart deployment kueue-controller-manager -n kueue-system
```

Verify the ProvisioningRequest controller started:

```bash
kubectl logs -n kueue-system -l control-plane=controller-manager | grep -i 'provisioning'
# Should see: "Successful initial Provisioning Request sync"
# Should NOT see: "Skipping provisioning controller setup"
```

### 2. Upgrade Cluster Autoscaler

Two flags are required:

```bash
helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
  -n <namespace> --reuse-values \
  --set extraArgs.enable-provisioning-requests=true \
  --set extraArgs.kube-api-content-type=application/json
```

| Flag | Purpose |
|------|---------|
| `--enable-provisioning-requests` | Enables the ProvisioningRequest processor in CA |
| `--kube-api-content-type=application/json` | Workaround for CA [bug #8855](https://github.com/kubernetes/autoscaler/issues/8855) — CA defaults to protobuf encoding which fails for CRD status updates |

**Important:** Always pin the chart version with `--version` when using `--reuse-values`. Without it, Helm pulls the latest chart which may be incompatible with your CA image.

### 3. Add Cluster Autoscaler RBAC

The CA Helm chart's built-in ClusterRole does not include ProvisioningRequest or PodTemplate permissions:

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler-provisioning-requests
rules:
  - apiGroups: ["autoscaling.x-k8s.io"]
    resources: ["provisioningrequests", "provisioningrequests/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["podtemplates"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-autoscaler-provisioning-requests
subjects:
  - kind: ServiceAccount
    name: cluster-autoscaler
    namespace: <ca-namespace>  # e.g., platforma or kube-system
roleRef:
  kind: ClusterRole
  name: cluster-autoscaler-provisioning-requests
  apiGroup: rbac.authorization.k8s.io
EOF
```

### 4. Upgrade Platforma Chart

```bash
helm upgrade platforma <chart-source> -n <namespace> --reuse-values --version <new-version>
```

The chart creates the ProvisioningRequestConfig, AdmissionCheck, and patches the batch ClusterQueue automatically.

## Verification

After upgrade, verify the full chain:

```bash
# 1. CRD exists
kubectl get crd provisioningrequests.autoscaling.x-k8s.io

# 2. Kueue ProvisioningRequest controller is active
kubectl logs -n kueue-system -l control-plane=controller-manager --tail=50 | grep -i provision
# Look for: "Successful initial Provisioning Request sync"

# 3. CA can process ProvisioningRequests
kubectl logs -n <ca-namespace> -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50 | grep -i provision
# Look for: "Successful initial Provisioning Request sync"
# Should NOT see: "protobuf marshalling" errors or "forbidden" errors

# 4. AdmissionCheck is active
kubectl get admissionchecks
# Should show platforma-provreq (or <release>-platforma-provreq)

# 5. Batch ClusterQueue references the AdmissionCheck and is Active
kubectl get clusterqueue <release>-platforma-batch -o yaml | grep -A5 'admissionChecksStrategy\|conditions'
# Should show: admissionChecks with platforma-provreq, condition Ready=True

# 6. UI ClusterQueue has NO admissionCheck (fast path)
kubectl get clusterqueue <release>-platforma-ui -o yaml | grep admissionChecksStrategy
# Should return empty
```

## Clusters Without Cluster Autoscaler

For bare-metal, Hetzner, or other clusters without a cloud autoscaler, disable ProvisioningRequest:

```yaml
# values.yaml
kueue:
  provisioningRequest:
    enabled: false
```

Without this, the AdmissionCheck stays Inactive and blocks all batch job admissions.

## Troubleshooting

### AdmissionCheck Inactive

```
Can't admit new workloads: references inactive AdmissionCheck(s): platforma-provreq
```

**Cause:** Kueue's ProvisioningRequest controller didn't start.

**Fix:** Check if the CRD exists (`kubectl get crd provisioningrequests.autoscaling.x-k8s.io`). If missing, install it and restart Kueue.

### CA Protobuf Error

```
object *v1.ProvisioningRequest does not implement the protobuf marshalling interface
```

**Cause:** Missing `--kube-api-content-type=application/json` flag on CA.

**Fix:** Add the flag and restart CA.

### CA RBAC Errors

```
provisioningrequests.autoscaling.x-k8s.io is forbidden
podtemplates is forbidden
```

**Cause:** CA ClusterRole missing ProvisioningRequest/PodTemplate permissions.

**Fix:** Apply the supplementary RBAC (Step 3 above).

### ProvisioningRequest Stays Without Conditions

CA syncs ProvisioningRequests but never sets `Accepted`/`Provisioned` conditions.

**Cause:** Wrong provisioning class name. CA expects FQDN names like `best-effort-atomic-scale-up.autoscaling.x-k8s.io`. Short names like `check-capacity` are silently ignored.

**Fix:** Verify the ProvisioningRequestConfig has the FQDN class name.

### Jobs Stuck at Scale-From-Zero With `check-capacity`

```
Provisioned: False, reason: CapacityIsNotFound
```

**Cause:** `check-capacity.autoscaling.x-k8s.io` only checks existing nodes. At scale-from-zero there's nothing to check.

**Fix:** Switch to `best-effort-atomic-scale-up.autoscaling.x-k8s.io` (the default).

### Kueue OOMKilled

```
Last State: Terminated, Reason: OOMKilled
```

**Cause:** Too many completed AppWrappers accumulating. Kueue watches all of them.

**Fix:** Increase Kueue memory limit to at least 1Gi. Clean up stale AppWrappers:

```bash
kubectl get appwrappers -n <namespace> --no-headers -o name | \
  xargs -n 100 kubectl delete -n <namespace> --wait=false
```
