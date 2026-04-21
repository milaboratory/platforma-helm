# Platforma Helm Chart

Production-ready Helm chart for deploying [Platforma](https://platforma.bio) on Kubernetes with Kueue job scheduling and AppWrapper.

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  -n platforma -f your-values.yaml
```

## Prerequisites

- Kubernetes 1.28+
- Helm 3.12+
- [Kueue](https://kueue.sigs.k8s.io/) 0.16.1+
- [AppWrapper](https://project-codeflare.github.io/appwrapper/) v1.2.0+
- RWX-capable storage (EFS, Filestore, NFS, etc.)
- License key from MiLaboratories

## Infrastructure setup

Before installing, set up your cluster infrastructure. Follow the guide for your environment:

- **[AWS EKS](infrastructure/aws/)** — EKS cluster, EFS, S3, Cluster Autoscaler, Kueue, AppWrapper
- **[GCP GKE](infrastructure/gcp/)** — GKE cluster, Filestore, GCS, Kueue, AppWrapper

These guides cover cluster creation, storage, node pools, autoscaling, and all prerequisites.

## Install

> **Note:** Steps 1-4 reference values files from the chart repository. Clone the repo or download files from [GitHub](https://github.com/milaboratory/platforma-helm).

### 1. Install Kueue

```bash
helm install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version 0.16.1 \
  -n kueue-system --create-namespace \
  -f infrastructure/aws/kueue-values.yaml  # or infrastructure/gcp/kueue-values.yaml
```

### 2. Install AppWrapper

```bash
kubectl apply --server-side -f https://github.com/project-codeflare/appwrapper/releases/download/v1.2.0/install.yaml
```

### 3. Create secrets

```bash
kubectl create namespace platforma

# License (required)
kubectl create secret generic platforma-license \
  -n platforma \
  --from-literal=MI_LICENSE="your-license-key"

# Authentication (required — choose one)
# Option A: htpasswd file
kubectl create secret generic platforma-htpasswd \
  -n platforma \
  --from-file=htpasswd=./htpasswd
# Option B: LDAP — configure auth.ldap.server in values file
```

### 4. Install Platforma

**AWS EKS (S3 primary storage):**
```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  -n platforma \
  -f infrastructure/aws/values-aws-s3.yaml \
  --set storage.main.s3.bucket=my-platforma-bucket \
  --set storage.main.s3.region=eu-central-1
```

**GCP GKE (GCS primary storage):**
```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  -n platforma \
  -f infrastructure/gcp/values-gcp-gcs.yaml \
  --set storage.workspace.filestore.ip=10.0.0.2 \
  --set storage.main.gcs.bucket=my-platforma-bucket \
  --set storage.main.gcs.projectId=my-project
```

**Generic NFS:**
```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  -n platforma \
  --set environment="" \
  --set auth.htpasswd.secretName=platforma-htpasswd \
  --set storage.workspace.nfs.enabled=true \
  --set storage.workspace.nfs.server=nfs.example.com \
  --set storage.workspace.nfs.path=/exports/platforma \
  --set storage.main.s3.bucket=my-bucket \
  --set storage.main.s3.region=eu-central-1
```

## Configuration

See [values.yaml](charts/platforma/values.yaml) for all options.

### Required values

| Value | Description |
|-------|-------------|
| `environment` | Cloud environment: `aws`, `gcp`, or `""` (vanilla K8s). Controls StorageClass creation. |
| `auth.htpasswd.secretName` or `auth.ldap.server` | Authentication method. At least one must be set. |
| `storage.workspace.*` | Exactly one RWX workspace option must be enabled. |
| `storage.main.s3.*` or `storage.main.gcs.*` | Primary storage bucket. |

### Storage

Platforma requires three storage areas:

| Area | Type | Description |
|------|------|-------------|
| Database | RWO | RocksDB state. Fast SSD recommended (gp3, pd-ssd). |
| Workspace | **RWX** | Shared job data. EFS, Filestore, or NFS. |
| Main | S3/GCS | Result storage exposed to Desktop App. |

### Workspace storage

The workspace is shared between the Platforma server pod and all job pods. It **must** be RWX (ReadWriteMany). Configure exactly one option:

| Option | Use case |
|--------|----------|
| `storage.workspace.pvc` | **Recommended for EFS.** Generic RWX PVC via StorageClass. |
| `storage.workspace.existingClaim` | Pre-created RWX PVC |
| `storage.workspace.efs` | AWS EFS (static PV, chart creates PV+PVC) |
| `storage.workspace.filestore` | GCP Filestore |
| `storage.workspace.fsxLustre` | AWS FSx for Lustre (high-performance) |
| `storage.workspace.nfs` | Generic NFS server |

#### File ownership and permissions

Platforma runs as a non-root user (UID 1010, GID 1010). The workspace must be writable by this user.

**AWS EFS — use a StorageClass with `uid`/`gid` parameters (recommended)**

Create a StorageClass that provisions EFS Access Points with the correct UID/GID:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-platforma
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0123456789abcdef
  directoryPerms: "755"
  uid: "1010"
  gid: "1010"
  basePath: "/dynamic"
```

Then use the `pvc` workspace option:

```yaml
storage:
  workspace:
    pvc:
      enabled: true
      storageClass: efs-platforma
      size: 100Gi
```

The EFS Access Point enforces UID/GID 1010 for all file operations, so no extra setup is needed. This is the simplest and most reliable approach. When `environment: aws` and `storage.workspace.efs.fileSystemId` is set, the chart creates this StorageClass automatically.

**AWS FSx for Lustre, GCP Filestore, NFS, generic PVC — automatic pre-install hook**

For workspace types without native UID/GID support, the chart automatically runs a Helm pre-install hook Job that `chown`s the workspace directory to UID/GID 1010 before the server starts. No manual configuration is needed.

```yaml
storage:
  workspace:
    fsxLustre:
      enabled: true
      fileSystemId: fs-0123456789abcdef
      dnsName: fs-0123456789abcdef.fsx.eu-central-1.amazonaws.com
      mountName: abcdefgh
```

Note: FSx Lustre requires the `lustre-client` package on all nodes. EKS AL2023 AMI does not include it by default — see the [AWS infrastructure guide](infrastructure/aws/) for installation steps.

**Performance comparison (tested on AWS):**

| Storage | Write throughput | Notes |
|---------|-----------------|-------|
| EFS | 30-45 MB/s | Consistent, scales with file count |
| FSx Lustre | 65-275 MB/s | Higher throughput, varies by instance type |

### Main storage (desktop app access)

The main storage is where Platforma stores results that the Desktop App downloads:

| Provider | Storage | Desktop App access |
|----------|---------|-------------------|
| `aws` | S3 | Direct to S3 |
| `gcp` | GCS | Direct to GCS |

The Desktop App accesses cloud storage directly — you only need the gRPC ingress for API connectivity.

### Authentication

Authentication is mandatory. Configure exactly one method:

**htpasswd (file-based):**

```yaml
auth:
  htpasswd:
    secretName: "platforma-htpasswd"  # kubectl create secret generic platforma-htpasswd --from-file=htpasswd=./htpasswd
```

**LDAP (direct bind):**

```yaml
auth:
  ldap:
    server: "ldap://ldap.example.com:389"
    bindDN: "cn=%u,ou=users,dc=example,dc=com"  # %u = username
```

**LDAP (search bind):**

```yaml
auth:
  ldap:
    server: "ldap://ldap.example.com:389"
    searchRules:
      - "(uid=%s)|ou=users,dc=example,dc=com"
    searchUser: "cn=readonly,dc=example,dc=com"
    searchPasswordSecretRef:
      name: "ldap-search-password"
      key: "password"
```

To disable auth for development, add `--no-auth` to `app.extraArgs`.

See [values.yaml](charts/platforma/values.yaml) `auth` section for TLS, CA certificates, and client certificate options.

### Service accounts

The chart creates two Kubernetes service accounts:

| Service account | Default name | Purpose |
|---|---|---|
| Server | `<release>-platforma` | Platforma pod — manages jobs, reads secrets |
| Jobs | `<release>-platforma-jobs` | Job pods — needs cloud storage access only |

Both names can be overridden via `serviceAccount.name` and `jobServiceAccount.name`.

#### Cloud IAM (OIDC)

To grant cloud permissions (S3/GCS access), annotate the service accounts with your IAM role/identity. Create the IAM role with an OIDC trust policy for the service account, then pass the ARN/email:

**AWS (IRSA):**
```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/platforma-server
jobServiceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/platforma-jobs
```

**GCP (Workload Identity):**
```yaml
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: platforma-server@project.iam.gserviceaccount.com
jobServiceAccount:
  annotations:
    iam.gke.io/gcp-service-account: platforma-jobs@project.iam.gserviceaccount.com
```

Alternatively, set `serviceAccount.create: false` and `serviceAccount.name: "my-sa"` to use a pre-existing service account.

### Networking

Platforma exposes a gRPC API on port 6345. The Desktop App connects here for all operations. When using S3 or GCS main storage, the Desktop App downloads results directly from the cloud — no additional ingress is needed.

The chart supports `ingress` and `additionalIngress` blocks with `host`, `tls`, and `annotations`.

#### AWS ALB Ingress Controller

The [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) creates an ALB per Ingress resource by default. To share a single ALB between Platforma and other services in the cluster, use the `group.name` annotation:

```yaml
ingress:
  enabled: true
  className: alb
  host: "platforma.example.com"
  annotations:
    alb.ingress.kubernetes.io/group.name: "shared"
    alb.ingress.kubernetes.io/group.order: "100"
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol-version: GRPC
    alb.ingress.kubernetes.io/healthcheck-path: /grpc.health.v1.Health/Check
    alb.ingress.kubernetes.io/success-codes: "0"
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:..."
```

How it works: all Ingress resources with the same `group.name` merge into one ALB. Each becomes a host-based routing rule pointing to its own target group. Other services in the cluster can join the same ALB by using the same `group.name` value. All resources in a group must agree on `scheme` (internet-facing vs internal).

#### nginx Ingress Controller

nginx runs as pods behind a single LoadBalancer Service. All Ingress resources are routing rules inside the controller — no additional load balancers per Ingress.

```yaml
ingress:
  enabled: true
  className: nginx
  host: "platforma.example.com"
  tls:
    enabled: true
    secretName: "platforma-tls"
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "GRPC"
```

nginx handles gRPC natively via the `backend-protocol: "GRPC"` annotation.

#### traefik Ingress Controller

traefik is the default ingress controller in k3s. It handles gRPC via HTTP/2 (h2c) to the backend:

```yaml
ingress:
  enabled: true
  className: traefik
  host: "platforma.example.com"
  tls:
    enabled: true
    secretName: "platforma-tls"
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
app:
  serviceAnnotations:
    traefik.ingress.kubernetes.io/service.serversscheme: h2c
```

#### Port-forwarding (development)

```bash
kubectl port-forward svc/platforma -n platforma 6345:6345
```

#### Choosing an approach

| Environment | Recommended | Notes |
|---|---|---|
| AWS with ALB Controller | ALB + `group.name` | Native AWS, ACM certs, WAF support |
| AWS with nginx/traefik | Use existing controller | One NLB already handles all services |
| GKE | GKE Ingress or nginx | GKE LB pricing differs from AWS |
| k3s / bare metal | traefik (ships with k3s) | Default, no extra install |
| Development | Port-forward | No ingress needed |

### Logging

By default, logs stream to container stderr and are collected by the cluster log driver. To persist logs to a PVC with rotation:

```yaml
app:
  logging:
    persistence:
      enabled: true
      size: 10Gi
      rotation:
        size: 1Gi     # Max size per log file
        count: 15     # Number of rotated files to keep
```

### Monitoring

Platforma exposes Prometheus metrics on port 9090 (hardcoded). A ClusterIP metrics service is always created.

To enable Prometheus scraping, add annotations to the metrics service:

```yaml
app:
  monitoring:
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "9090"
```

For GKE with Google Managed Prometheus, enable the PodMonitoring resource:

```yaml
app:
  monitoring:
    gkeMonitoring:
      enabled: true
      interval: 30s
```

### Debug

The debug API (pprof, DB inspection) always runs on port 9091. By default it binds to 127.0.0.1 (pod-internal only). To make it accessible via port-forward:

```yaml
app:
  debug:
    enabled: true  # Binds on 0.0.0.0, sets log level to debug, keeps workdirs for 1h
```

### Kueue modes

| Mode | Description |
|------|-------------|
| `dedicated` (default) | Chart creates all Kueue resources |
| `shared` | Chart references externally-managed cluster resources, creates LocalQueues |

#### What each mode creates

| Resource | Scope | Dedicated (primary) | Dedicated (secondary) | Shared |
|----------|-------|--------------------|-----------------------|--------|
| ResourceFlavors | Cluster | Created | Skipped | External |
| ClusterQueues | Cluster | Created | Skipped | External |
| WorkloadPriorityClasses | Cluster | Created | Skipped | External |
| LocalQueues | Namespace | Created | Created | Created |
| Job template ConfigMap | Namespace | Created | Created | Created |

#### Dedicated mode: single install

Default behavior — chart creates all Kueue resources:

```yaml
kueue:
  mode: dedicated
```

#### Dedicated mode: multiple installs

When deploying multiple Platforma instances on the same cluster sharing node pools:

**First install** (creates cluster infrastructure):
```yaml
kueue:
  mode: dedicated
  dedicated:
    clusterResourceName: "platforma"  # stable name shared across installs
```

**Second install** (references first install's cluster resources):
```yaml
kueue:
  mode: dedicated
  dedicated:
    createClusterResources: false       # skip cluster-scoped resources
    clusterResourceName: "platforma"    # must match first install
```

Both installs create their own LocalQueues pointing at the same ClusterQueues. Jobs from both namespaces compete fairly in the shared queues.

> **Note:** The primary install (with `createClusterResources: true`) owns the cluster-scoped resources and must be uninstalled last.

#### Shared mode

For clusters where Kueue infrastructure is managed externally (e.g., by a platform team). You must create ClusterQueues, ResourceFlavors, and WorkloadPriorityClasses outside the chart. The chart creates LocalQueues pointing at your ClusterQueues:

```yaml
kueue:
  mode: shared
  shared:
    clusterQueues:
      ui: "my-ui-clusterqueue"
      batch: "my-batch-clusterqueue"
    priorities:
      uiTasks: "my-ui-priority"
      high: "my-high-priority"
      normal: "my-normal-priority"
      low: "my-low-priority"
```

### Job queues

Platforma uses 4 fixed queues routed to 2 node pools:

```
  ui-tasks (pri:1000)  ──► UI LocalQueue   ──► UI ClusterQueue   ──► UI Nodes
  heavy    (pri:1000)  ─┐
  medium   (pri:100)   ─┼► Batch LocalQueue ──► Batch ClusterQueue ──► Batch Nodes
  light    (pri:10)    ─┘
```

Priority within the batch queue: heavy > medium > light.

### Data sources (data library)

Mount external read-only data (reference genomes, sequencing archives) accessible to Platforma.

**AWS S3 with IRSA** (no credentials needed — IAM role on service account):

```yaml
dataSources:
  - name: "sequencing-archive"
    type: s3
    s3:
      bucket: "company-sequencing"
      region: "eu-central-1"
```

**S3 with explicit credentials** (non-AWS or non-IRSA):

```yaml
dataSources:
  - name: "sequencing-archive"
    type: s3
    s3:
      bucket: "company-sequencing"
      region: "eu-central-1"
      secretRef:
        name: "sequencing-archive-creds"   # K8s Secret name
        accessKeyField: "access-key"        # default
        secretKeyField: "secret-key"        # default
```

Create the Secret:

```bash
kubectl create secret generic sequencing-archive-creds \
  --from-literal=access-key=AKIAIOSFODNN7EXAMPLE \
  --from-literal=secret-key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  -n platforma
```

**S3-compatible storage** (MinIO, Ceph, Wasabi):

```yaml
dataSources:
  - name: "minio-library"
    type: s3
    s3:
      bucket: "references"
      region: "us-east-1"
      secretRef:
        name: "minio-creds"
      externalEndpoint: "https://minio.example.com"  # URL for Desktop App direct access
      noDataIntegrity: true  # Required for Ceph, old MinIO, and GCS
```

**PVC** (local cluster storage):

```yaml
dataSources:
  - name: "local-data"
    type: pvc
    pvc:
      existingClaim: "shared-data-pvc"
```

### Extra CLI arguments

Additional Platforma CLI arguments can be passed via `app.extraArgs`. See [values.yaml](charts/platforma/values.yaml) for examples.

## Upgrade

```bash
helm upgrade platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.1 -n platforma -f your-values.yaml
```

Running jobs are not interrupted during upgrades. The deployment uses `strategy: Recreate`.

## Uninstall

```bash
helm uninstall platforma -n platforma
```

PVCs are not deleted automatically:
```bash
kubectl delete pvc -n platforma -l app.kubernetes.io/instance=platforma
```

## Troubleshooting

### Jobs stuck in pending

```bash
kubectl get pods -n kueue-system          # Kueue running?
kubectl get pods -n appwrapper-system     # AppWrapper running?
kubectl get clusterqueues                  # Queue status
kubectl get workloads -n platforma         # Workload admission
```

### Desktop app can't connect

```bash
kubectl get svc -n platforma
kubectl logs -n platforma -l app.kubernetes.io/name=platforma --tail=50
```

### Workspace storage errors
Workspace must be RWX (ReadWriteMany). Block storage (EBS, PD) is not supported.

## License

Proprietary - MiLaboratories
