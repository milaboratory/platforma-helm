# Migration: Single-Server Platforma → Kubernetes

End-to-end procedure to move an existing single-server Platforma instance (running the standalone binary or Docker image) onto a Kubernetes cluster managed by this Helm chart.

The migration moves two pieces of state:

1. **Database** — RocksDB on the source server, dumped to a gzipped file and restored into the chart's `platforma-database` PVC.
2. **Primary storage** — bucket-to-bucket S3 sync (or equivalent on GCP) into the new cloud bucket the cluster will use.

The procedure is split into two phases that run before and after the `helm install`. Both phases are idempotent: each step writes a `/data/database/.migration-complete` marker so reruns are no-ops.

## Audience and Scope

This guide is written for an operator standing up the target cluster with **Terraform** (or any IaC equivalent of `eksctl` / CloudFormation). It assumes:

- You have provisioned the target cluster's infrastructure following the resources listed in [`infrastructure/aws/advanced-installation.md`](infrastructure/aws/advanced-installation.md) — that doc enumerates every IAM policy, IRSA role, S3 bucket, EFS filesystem, ACM certificate, and StorageClass that the Helm chart depends on. Translate each `aws ...` call into the equivalent Terraform resource.
- You have `kubectl` access to the cluster and admin permissions in the target namespace (`platforma` by default).
- You have AWS CLI access to both the **source** primary-storage S3 bucket (read) and the **destination** bucket (write). Cross-account migrations need an extra IAM user — see [Cross-Account Sync](#cross-account-sync) below.

If you are setting up the cluster from scratch on AWS using CloudFormation, the same migration is wired into [`cloudformation-eks-1-35.yaml`](infrastructure/aws/cloudformation-eks-1-35.yaml) via the `MigrationDatabaseS3Uri` / `MigrationSourceBucket` parameters. This guide is the manual equivalent.

## Prerequisites

| Requirement | Notes |
|---|---|
| Source Platforma version | Same major.minor as the target chart's image. Cross-version restore is not supported. |
| Source database dump | Created with `curl http://localhost:9091/db/state_raw \| gzip > backup.gz`, then uploaded to S3. The endpoint is part of the debug API (port 9091 on the source server). |
| Target cluster ready | Cluster Autoscaler, Kueue + AppWrapper, EFS CSI, EBS CSI, S3 IRSA all working. See [advanced-installation.md](infrastructure/aws/advanced-installation.md) Steps 1–8. |
| Target S3 bucket created | Empty. The migration will sync data into it. |
| `MI_LICENSE` available | The migration uses the Platforma image to run `--restore-db` and `--invalidate-caches`, both of which need a valid license. |
| `kubectl` and AWS CLI | Configured for the target cluster and account. |
| Source instance frozen | Stop writes during the migration. The DB dump is a point-in-time snapshot. New work submitted after the dump is taken will be lost. |

## Migration Variables

Set these once before running any step. Each pre-helm command references them.

```bash
# Target cluster
export NAMESPACE="platforma"
export REGION="eu-central-1"
export S3_BUCKET="platforma-<your-cluster>-<suffix>"   # destination bucket (already created)
export PLATFORMA_VERSION="3.0.1"

# Source dump (required)
export MIGRATION_DATABASE_S3_URI="s3://my-backups/platforma-backup.gz"

# Source primary storage (optional — omit to skip storage sync)
export MIGRATION_SOURCE_BUCKET="old-platforma-bucket"
export MIGRATION_SOURCE_PREFIX=""              # leave empty for bucket root
export MIGRATION_SOURCE_REGION="eu-west-1"     # defaults to $REGION if empty

# Cross-account credentials (optional)
export MIGRATION_DB_ACCESS_KEY=""              # AKIA... — needed if dump is in another account
export MIGRATION_DB_SECRET_KEY=""
export MIGRATION_STORAGE_ACCESS_KEY=""         # AKIA... — needed if source bucket is in another account
export MIGRATION_STORAGE_SECRET_KEY=""
```

## Architecture of the Migration Job

All migration work runs as one-shot pods inside the target namespace. They use:

- The official Platforma image (`quay.io/milaboratories/platforma:${PLATFORMA_VERSION}`) for DB restore and cache invalidation.
- The `amazon/aws-cli:2.27.22` image for S3 download/sync.
- Pod `securityContext`: `fsGroup: 1010`, `runAsUser: 1010`, `runAsGroup: 1010` (matches the chart's non-root `pl` user — UID/GID **must** be 1010 or restored RocksDB files will be unreadable by the server pod).
- The `platforma-database` PVC (RWO, 50Gi, gp3) mounted at `/data/database`.
- The `platforma-license` Secret for the Platforma-image pods.

The reference implementation is the script at [`infrastructure/aws/migration.sh`](infrastructure/aws/migration.sh). The YAML below is what that script generates and applies — provided here so you can run the migration manually or wire it into your own Terraform `null_resource` / `helm_release` `provisioner`.

---

## Phase 1: Pre-Helm

Goal: have a populated `platforma-database` PVC and a fully-synced primary-storage bucket **before** `helm install` runs, so that the chart's first-run reconciliation sees a healthy database.

### Step 1.1: Create Namespace, StorageClass, License Secret

```bash
kubectl create namespace ${NAMESPACE} 2>/dev/null || true

kubectl create secret generic platforma-license \
  -n ${NAMESPACE} \
  --from-literal=MI_LICENSE="${MI_LICENSE}"
```

If the cluster does not already have a `gp3` StorageClass, create one. Labels and annotations let Helm adopt it later — without them, `helm install` fails with `invalid ownership metadata`.

```yaml
# gp3-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: platforma
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
```

```bash
kubectl apply -f gp3-storageclass.yaml
```

### Step 1.2: Pre-Create the Database PVC

The chart will adopt this PVC on install. Same labelling trick as the StorageClass.

```yaml
# database-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: platforma-database
  namespace: platforma
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: platforma
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
```

```bash
kubectl apply -f database-pvc.yaml
```

### Step 1.3: Download the Database Dump

```yaml
# mgr-download.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-download
  namespace: platforma
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: platforma-database
  containers:
    - name: mgr-download
      image: amazon/aws-cli:2.27.22
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          aws s3 cp ${MIGRATION_DATABASE_S3_URI} /data/database/backup.gz
          echo Download complete
      env:
        # Only needed for cross-account dumps
        - { name: AWS_ACCESS_KEY_ID,     value: "${MIGRATION_DB_ACCESS_KEY}" }
        - { name: AWS_SECRET_ACCESS_KEY, value: "${MIGRATION_DB_SECRET_KEY}" }
      volumeMounts:
        - { name: db, mountPath: /data/database }
```

If the dump bucket is in the **same** AWS account and the cluster has IRSA wired up, drop the `env:` block and the pod will use IRSA via the default service account. Otherwise inline the access keys (or mount them from a Secret).

```bash
envsubst < mgr-download.yaml | kubectl apply -f -
kubectl wait pod/mgr-download -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
kubectl logs mgr-download -n ${NAMESPACE}
kubectl delete pod/mgr-download -n ${NAMESPACE}
```

### Step 1.4: Restore the Database

```yaml
# mgr-restore.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-restore
  namespace: platforma
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - { name: db,   persistentVolumeClaim: { claimName: platforma-database } }
    - { name: main, emptyDir: {} }
  containers:
    - name: mgr-restore
      image: quay.io/milaboratories/platforma:${PLATFORMA_VERSION}
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          /app/platforma --restore-db=/data/database/backup.gz --db-dir=/data/database --force
          echo Database restored
      env:
        - name: PL_LICENSE
          valueFrom:
            secretKeyRef: { name: platforma-license, key: MI_LICENSE }
      volumeMounts:
        - { name: db,   mountPath: /data/database }
        - { name: main, mountPath: /data/main }
```

```bash
envsubst < mgr-restore.yaml | kubectl apply -f -
kubectl wait pod/mgr-restore -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=1800s
kubectl logs mgr-restore -n ${NAMESPACE}
kubectl delete pod/mgr-restore -n ${NAMESPACE}
```

`--force` overwrites any partial DB from a previous attempt. Restore time scales with dump size — give a generous timeout (default 30 min above; bump to several hours for multi-hundred-GB dumps).

### Step 1.5: Sync Primary Storage

Skip this step if your source instance kept its primary storage on a local filesystem and you want the new cluster to start with an empty bucket.

```yaml
# mgr-sync.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-sync
  namespace: platforma
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - { name: db, persistentVolumeClaim: { claimName: platforma-database } }
  containers:
    - name: mgr-sync
      image: amazon/aws-cli:2.27.22
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          aws s3 sync s3://${MIGRATION_SOURCE_BUCKET}/${MIGRATION_SOURCE_PREFIX} \
                       s3://${S3_BUCKET}/ \
                       --source-region ${MIGRATION_SOURCE_REGION} \
                       --region ${REGION} \
                       --no-progress --copy-props none
          echo Storage sync complete
      env:
        # Only needed for cross-account source bucket
        - { name: AWS_ACCESS_KEY_ID,     value: "${MIGRATION_STORAGE_ACCESS_KEY}" }
        - { name: AWS_SECRET_ACCESS_KEY, value: "${MIGRATION_STORAGE_SECRET_KEY}" }
      volumeMounts:
        - { name: db, mountPath: /data/database }
```

```bash
envsubst < mgr-sync.yaml | kubectl apply -f -
kubectl wait pod/mgr-sync -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=86400s
kubectl logs -f mgr-sync -n ${NAMESPACE}
kubectl delete pod/mgr-sync -n ${NAMESPACE}
```

`--copy-props none` skips ACL and tag copies that frequently fail across accounts; the destination uses bucket-default encryption.

### Step 1.6: Delete the Dump File

```bash
kubectl run mgr-cleanup -n ${NAMESPACE} --restart=Never \
  --image=amazon/aws-cli:2.27.22 \
  --overrides='{"spec":{"securityContext":{"fsGroup":1010,"runAsUser":1010,"runAsGroup":1010},"containers":[{"name":"mgr-cleanup","image":"amazon/aws-cli:2.27.22","command":["sh","-ec","rm -f /data/database/backup.gz"],"volumeMounts":[{"name":"db","mountPath":"/data/database"}]}],"volumes":[{"name":"db","persistentVolumeClaim":{"claimName":"platforma-database"}}]}}'
kubectl wait pod/mgr-cleanup -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl delete pod/mgr-cleanup -n ${NAMESPACE}
```

---

## Phase 2: Helm Install

Standard install — see [`README.md`](README.md) and [`advanced-installation.md`](infrastructure/aws/advanced-installation.md) Step 10. The chart adopts the pre-existing PVC and StorageClass and starts the Platforma server. On first start the server applies any in-binary schema migrations against the restored DB.

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version ${PLATFORMA_VERSION} \
  -n ${NAMESPACE} \
  -f infrastructure/aws/values-aws-s3.yaml \
  --set storage.main.s3.bucket=${S3_BUCKET} \
  --set storage.main.s3.region=${REGION} \
  ...   # other --set flags from advanced-installation.md Step 10
```

Wait for the rollout to settle:

```bash
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=platforma -n ${NAMESPACE} --timeout=300s
```

---

## Phase 3: Post-Helm (Cache Invalidation)

After the chart's first reconciliation, internal caches in the restored DB still point at the **old** primary-storage URLs. Invalidating them rewrites those references to the new bucket.

The Platforma binary that runs invalidation needs exclusive RWO access to the database PVC, so we briefly scale the server down to zero.

### Step 3.1: Scale Platforma Down

```bash
kubectl scale deployment/platforma -n ${NAMESPACE} --replicas=0
kubectl wait --for=delete pod -l app.kubernetes.io/name=platforma \
  -n ${NAMESPACE} --timeout=120s
```

### Step 3.2: Run Invalidation

```yaml
# mgr-invalidate.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-invalidate
  namespace: platforma
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - { name: db,   persistentVolumeClaim: { claimName: platforma-database } }
    - { name: main, emptyDir: {} }
  containers:
    - name: mgr-invalidate
      image: quay.io/milaboratories/platforma:${PLATFORMA_VERSION}
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          /app/platforma --invalidate-caches --main-root=/data/main --db-dir=/data/database
          date -u > /data/database/.migration-complete
          echo Caches invalidated
      env:
        - name: PL_LICENSE
          valueFrom:
            secretKeyRef: { name: platforma-license, key: MI_LICENSE }
      volumeMounts:
        - { name: db,   mountPath: /data/database }
        - { name: main, mountPath: /data/main }
```

```bash
envsubst < mgr-invalidate.yaml | kubectl apply -f -
kubectl wait pod/mgr-invalidate -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=1800s
kubectl logs mgr-invalidate -n ${NAMESPACE}
kubectl delete pod/mgr-invalidate -n ${NAMESPACE}
```

The marker file `/data/database/.migration-complete` makes this and every previous step a no-op on re-run.

### Step 3.3: Scale Platforma Back Up

```bash
kubectl scale deployment/platforma -n ${NAMESPACE} --replicas=1
kubectl rollout status deployment/platforma -n ${NAMESPACE} --timeout=300s
```

---

## Verification

```bash
kubectl get pvc -n ${NAMESPACE}                # platforma-database Bound, > 0 used
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=platforma | grep -i 'ready\|migration'
aws s3 ls s3://${S3_BUCKET}/ --summarize       # object count matches source
```

Connect from the Desktop App; existing projects, results, and credentials should appear.

---

## Cross-Account Sync

If the source S3 bucket lives in a different AWS account, the destination bucket policy must grant the source identity write access. Pattern: create an IAM user (or role) in the **source** account, generate access keys, and add a bucket policy on the **destination** bucket like:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<source-account>:user/migration-user" },
    "Action": ["s3:PutObject", "s3:ListBucket", "s3:AbortMultipartUpload"],
    "Resource": [
      "arn:aws:s3:::${S3_BUCKET}",
      "arn:aws:s3:::${S3_BUCKET}/*"
    ]
  }]
}
```

Then export the access keys as `MIGRATION_STORAGE_ACCESS_KEY` / `MIGRATION_STORAGE_SECRET_KEY` (Step 1.5). The same pattern applies to the database-dump bucket (`MIGRATION_DB_*`).

---

## Rollback

If the migration fails after `helm install`:

1. `helm uninstall platforma -n ${NAMESPACE}` — removes the Deployment but **keeps PVCs by default**. Verify with `kubectl get pvc -n ${NAMESPACE}`.
2. `kubectl delete pvc platforma-database -n ${NAMESPACE}` — wipe the bad DB.
3. Repeat Phase 1 with the same dump.

The source single-server instance is untouched throughout — keep it running until you have validated the new cluster.

---

# Component Options Reference

The migration itself touches three cluster components: Cluster Autoscaler, Kueue, and AppWrapper. The full options surface for each is below.

## Cluster Autoscaler

Installed in [`advanced-installation.md`](infrastructure/aws/advanced-installation.md) Step 3. Helm chart: `autoscaler/cluster-autoscaler` v9.56.0, image tag `v1.35.0` (must match EKS minor — chart `9.X.Y` → image `v1.X.0` where X = EKS minor).

**All `extraArgs` used by the production install:**

| Flag | Production | Dev/Test | Why |
|---|---|---|---|
| `scale-down-delay-after-add` | `10m` | `2m` | Grace period after scale-up before scale-down is considered. Higher values reduce flapping but waste capacity. |
| `scale-down-unneeded-time` | `10m` | `2m` | Time a node must be underutilized before removal. |
| `scale-down-utilization-threshold` | `0.5` | `0.5` | Fraction of allocatable CPU+memory below which a node is considered for removal. |
| `expander` | `least-waste` | `least-waste` | Strategy for picking which node group to scale up. `least-waste` minimises CPU/memory left over after fitting pending pods — best for heterogeneous batch fleets. Other choices: `random`, `most-pods`, `priority`. |
| `max-node-provision-time` | `5m` | `5m` | Max wait for a new node to become Ready. EKS provisions in 60–90 s; default 15 m masks failures. |
| `initial-node-group-backoff-duration` | `1m` | `1m` | Backoff after a failed scale-up attempt. Default is 5m. |
| `max-node-group-backoff-duration` | `5m` | `5m` | Backoff cap after repeated failures. Default is 30m. |
| `enable-provisioning-requests` | `true` | `true` | Enables the [`ProvisioningRequest`](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/provisioningrequest/README.md) API, which lets Kueue ask the autoscaler "could you fit this whole AppWrapper if I admitted it?" before admission. Prevents partial-admission deadlocks where Kueue admits a job, scales up a few nodes, but never enough to actually run it. |
| `kube-api-content-type` | `application/json` | `application/json` | Workaround for [autoscaler #8855](https://github.com/kubernetes/autoscaler/issues/8855): the default `application/vnd.kubernetes.protobuf` causes `ProvisioningRequest` status updates to fail silently. |

**Auto-discovery tag:** `eks:cluster-name=<CLUSTER_NAME>` — EKS adds this to every managed node group's ASG automatically. The autoscaler matches it via `autoDiscovery.tags[0]`.

**IAM scoping:** the only writable actions (`SetDesiredCapacity`, `TerminateInstanceInAutoScalingGroup`) are conditioned on `autoscaling:ResourceTag/eks:cluster-name=${CLUSTER_NAME}`. Note: the condition key is `autoscaling:ResourceTag`, **not** `aws:ResourceTag` — the latter silently denies and the autoscaler hangs.

**ProvisioningRequest CRD:** install before the autoscaler starts (it watches the CRD on boot):

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/kubernetes/autoscaler/cluster-autoscaler-1.35.0/cluster-autoscaler/apis/config/crd/autoscaling.x-k8s.io_provisioningrequests.yaml
```

The autoscaler's bundled ClusterRole does **not** grant ProvisioningRequest or PodTemplate access. Add this ClusterRoleBinding (see Step 3 of `advanced-installation.md` for the full YAML):

```yaml
rules:
  - apiGroups: ["autoscaling.x-k8s.io"]
    resources: ["provisioningrequests", "provisioningrequests/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["podtemplates"]
    verbs: ["get", "list", "watch"]
```

**Operational gotcha:** after a failed scale-up, the autoscaler enters per-node-group backoff. To clear it without waiting:

```bash
kubectl delete pod -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
```

## Kueue

Installed in `advanced-installation.md` Step 8. OCI chart: `oci://registry.k8s.io/kueue/charts/kueue` v0.16.1 (no leading `v` in the version, with `/charts/` in the path).

**Helm values used in production** (full file: [`infrastructure/aws/kueue-values.yaml`](infrastructure/aws/kueue-values.yaml)):

```yaml
controllerManager:
  manager:
    resources:
      requests: { cpu: 100m, memory: 512Mi }
      limits:   { cpu: 500m, memory: 1Gi }

featureGates:
  AppWrapper: true        # enables the AppWrapper integration (separate controller — see below)
  ProvisioningACC: true   # enables ProvisioningRequest-based admission checks (default-on in 0.10+;
                          # listed explicitly so it's obvious in code review)

integrations:
  frameworks:
    - "batch/job"
    - "jobset.x-k8s.io/jobset"
    - "workload.codeflare.dev/appwrapper"
  podOptions:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, kueue-system]    # never gate system pods through Kueue

metrics:
  enableClusterQueueResources: true              # /metrics exposes per-ClusterQueue usage
```

**Chart-level Kueue knobs** (in `charts/platforma/values.yaml`, applied automatically when `kueue.mode=dedicated`):

| Path | Default | Description |
|---|---|---|
| `kueue.mode` | `dedicated` | `dedicated`: chart creates ClusterQueues, ResourceFlavors, LocalQueues, WorkloadPriorityClasses. `shared`: chart creates only LocalQueues that point at admin-managed ClusterQueues. Use `shared` for multi-tenant clusters. |
| `kueue.maxJobResources.cpu` | `64` | Largest CPU request a single job can declare. Jobs above this are rejected at admission. |
| `kueue.maxJobResources.memory` | `256Gi` | Largest memory request per job. |
| `kueue.pools.ui.nodeSelector` | `{}` | Where UI/interactive jobs run. AWS: `{ node.kubernetes.io/pool: ui }`. GKE: `{ pool: ui }` (the `node.kubernetes.io/` prefix is reserved on GKE). |
| `kueue.pools.ui.tolerations` | `[]` | Tolerations matching the UI node group's taint. |
| `kueue.pools.batch.nodeSelector` | `{}` | Where batch jobs run. |
| `kueue.pools.batch.tolerations` | `[]` | Match the batch taint. |
| `kueue.dedicated.createClusterResources` | `true` | Set to `false` for secondary Platforma installs that share Kueue infra with a primary install in the same cluster. |
| `kueue.dedicated.clusterResourceName` | `""` (= release fullname) | Shared name prefix when multiple releases share a single set of ClusterQueues — all releases must use the same value. |
| `kueue.dedicated.resources.ui.cpu` | `64` | UI ClusterQueue CPU quota — guaranteed (never lent to batch). |
| `kueue.dedicated.resources.ui.memory` | `256Gi` | UI ClusterQueue memory quota. |
| `kueue.dedicated.resources.batch.cpu` | `256` | Batch ClusterQueue CPU quota. Can borrow idle UI capacity at runtime. |
| `kueue.dedicated.resources.batch.memory` | `1024Gi` | Batch ClusterQueue memory quota. |
| `kueue.shared.clusterQueues.ui` | `""` | (shared mode) name of the existing UI ClusterQueue. |
| `kueue.shared.clusterQueues.batch` | `""` | (shared mode) name of the existing batch ClusterQueue. |
| `kueue.shared.workloadPriorityClasses.uiTasks` | `""` | (shared mode) priority class for UI tasks. |
| `kueue.shared.workloadPriorityClasses.high` | `""` | (shared mode) priority class for high-priority batch. |
| `kueue.shared.workloadPriorityClasses.normal` | `""` | (shared mode) normal-priority batch. |
| `kueue.shared.workloadPriorityClasses.low` | `""` | (shared mode) low-priority batch. |

The `dedicated.resources.*` quotas should align with what Cluster Autoscaler can actually provide (sum of the max sizes of all batch ASGs × instance vCPU / RAM). Setting them higher just causes ProvisioningRequest checks to deny admissions.

## AppWrapper

Installed in `advanced-installation.md` Step 8. AppWrapper ships its own controller and CRD — it is **not** bundled with Kueue.

```bash
kubectl apply --server-side -f \
  https://github.com/project-codeflare/appwrapper/releases/download/v1.2.0/install.yaml

kubectl wait --for=condition=Available deployment/appwrapper-controller-manager \
  -n appwrapper-system --timeout=120s
```

**Required workaround — delete both webhooks immediately after install:**

```bash
kubectl delete validatingwebhookconfiguration appwrapper-validating-webhook-configuration --ignore-not-found
kubectl delete mutatingwebhookconfiguration   appwrapper-mutating-webhook-configuration   --ignore-not-found
```

The mutating webhook injects the IAM role ARN as a label value. The ARN contains `:` (e.g. `arn:aws:iam::934685779402:role/...`), which is illegal in a Kubernetes label value, so every AppWrapper admission fails with `metadata.labels: Invalid value`. Deleting the webhooks removes the injection; the controller still runs and reconciles AppWrappers normally.

**Verify the install:**

```bash
kubectl get crd appwrappers.workload.codeflare.dev
kubectl get pods -n appwrapper-system
kubectl get clusterqueues
kubectl get localqueues -n ${NAMESPACE}
```

The Helm chart wraps every job pod into an AppWrapper automatically when `kueue.featureGates.AppWrapper=true` and `workload.codeflare.dev/appwrapper` is in `integrations.frameworks`.

---

## See Also

- [Reference migration script](infrastructure/aws/migration.sh) — the ground-truth implementation; the YAML in this document is what it generates.
- [`advanced-installation.md`](infrastructure/aws/advanced-installation.md) — full manual cluster setup; mirror it in Terraform.
- [`cloudformation-eks-1-35.yaml`](infrastructure/aws/cloudformation-eks-1-35.yaml) — single-template AWS deployment that runs this same migration via CodeBuild.
- [Kueue docs](https://kueue.sigs.k8s.io/docs/) and [AppWrapper docs](https://project-codeflare.github.io/appwrapper/).
