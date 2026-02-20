# GCP permissions reference

Permissions required for deploying and running Platforma on GCP GKE.

---

## 1. Deployer permissions

IAM roles required by the user or service account creating infrastructure.

| Role | Purpose |
|------|---------|
| `roles/container.admin` | Create and manage GKE clusters and node pools |
| `roles/file.editor` | Create and manage Filestore instances |
| `roles/storage.admin` | Create and configure GCS buckets |
| `roles/iam.serviceAccountAdmin` | Create Google service accounts |
| `roles/resourcemanager.projectIamAdmin` | Bind IAM roles to service accounts |
| `roles/compute.networkAdmin` | Only if creating custom VPC (default network requires no extra permissions) |

---

## 2. GKE node service account

The default compute service account (or a custom node SA) needs:

| Role | Purpose |
|------|---------|
| `roles/logging.logWriter` | Write logs to Cloud Logging |
| `roles/monitoring.metricWriter` | Write metrics to Cloud Monitoring |
| `roles/artifactregistry.reader` | Pull container images from Artifact Registry |

---

## 3. Platforma service account (Workload Identity)

Bound to Kubernetes service account `platforma` in namespace `platforma` via GKE Workload Identity. The Google service account (GSA) is annotated on the KSA with `iam.gke.io/gcp-service-account`.

### Minimum (GCS primary storage only)

| Role | Scope | Purpose |
|------|-------|---------|
| `roles/storage.objectAdmin` | Primary GCS bucket | Read/write objects in primary storage |
| `roles/iam.workloadIdentityUser` | GSA | Allow KSA to impersonate the GSA |

### Full production (GCS + Batch + signed URLs + logging)

| Role | Scope | Purpose |
|------|-------|---------|
| `roles/storage.objectAdmin` | Primary GCS bucket | Read/write objects in primary storage |
| `roles/storage.objectViewer` | Library GCS bucket | Read-only access to shared data libraries |
| `roles/batch.jobsEditor` | Project | Submit and manage GCP Batch jobs |
| `roles/batch.agentReporter` | Project | Batch agent VM status reporting |
| `roles/iam.serviceAccountUser` | GSA | Run Batch jobs as itself |
| `roles/iam.serviceAccountTokenCreator` | Project | Sign blobs for GCS signed URLs |
| `roles/artifactregistry.reader` | Project | Pull container images from Artifact Registry |
| `roles/logging.logWriter` | Project | Write to Cloud Logging |
| `roles/iam.workloadIdentityUser` | GSA | Allow KSA to impersonate the GSA |

---

## 4. GCP resources reference

Recommended resource configuration for a production Platforma deployment.

### Cluster

| Setting | Recommended value |
|---------|-------------------|
| Type | Regional (3 zones) |
| Release channel | Regular |
| Workload Identity | Enabled (`--workload-pool=${PROJECT_ID}.svc.id.goog`) |
| Networking | VPC-native (`--enable-ip-alias`) |

### Node pools

| Pool | Machine type | Min/zone | Max/zone | Labels | Taints |
|------|-------------|----------|----------|--------|--------|
| `system` (default) | e2-standard-4 | 1 | 1 | `pool=system` | *(none)* |
| `ui` | e2-standard-4 | 0 | 4 | `pool=ui` | `dedicated=ui:NoSchedule` |
| `batch-medium` | n2-standard-8 | 0 | 10 | `pool=batch` | `dedicated=batch:NoSchedule` |
| `batch-large` | n2-standard-16 | 0 | 10 | `pool=batch` | `dedicated=batch:NoSchedule` |
| `batch-xlarge` | n2-standard-32 | 0 | 10 | `pool=batch` | `dedicated=batch:NoSchedule` |

All three batch pools share the same label (`pool=batch`) and taint. GKE's built-in autoscaler selects the smallest pool that fits each pending pod.

**Important:** Do not use the `node.kubernetes.io/` label prefix on GKE — it is reserved. Use plain labels (e.g. `pool=batch`).

### Storage

| Resource | Type | Recommended settings |
|----------|------|---------------------|
| Filestore | BASIC_SSD | 2560 GB / 2.5 TiB (minimum for SSD tier), same zone as cluster |
| GCS bucket | Standard | Same region, uniform bucket-level access |

### Identity

| Resource | Configuration |
|----------|--------------|
| Google service account (GSA) | `platforma-access@${PROJECT_ID}.iam.gserviceaccount.com` |
| Workload Identity binding | KSA `platforma` in namespace `platforma` → GSA |

---

## 5. Kubernetes RBAC

The Helm chart creates a `Role` and `RoleBinding` in the release namespace granting the Platforma service account access to: pods, jobs, configmaps, secrets, events, persistentvolumeclaims. No cluster-level permissions.
