# Platforma Helm Chart

Production-ready Helm chart for deploying [Platforma](https://platforma.bio) on Kubernetes with Kueue job scheduling and AppWrapper.

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 -n platforma -f your-values.yaml
```

## Prerequisites

- Kubernetes 1.28+
- Helm 3.12+
- [Kueue](https://kueue.sigs.k8s.io/) 0.16.1+
- [AppWrapper](https://project-codeflare.github.io/appwrapper/) v1.1.2+
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
kubectl apply --server-side -f https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml
```

### 3. Create license secret

```bash
kubectl create namespace platforma
kubectl create secret generic platforma-license \
  -n platforma \
  --from-literal=MI_LICENSE="your-license-key"
```

### 4. Install Platforma

**AWS EKS (S3 primary storage):**
```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 \
  -n platforma \
  -f infrastructure/aws/values-aws-s3.yaml \
  --set storage.main.s3.bucket=my-platforma-bucket \
  --set storage.main.s3.region=eu-central-1
```

**GCP GKE (GCS primary storage):**
```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 \
  -n platforma \
  -f infrastructure/gcp/values-gcp-gcs.yaml \
  --set storage.workspace.filestore.ip=10.0.0.2 \
  --set storage.main.gcs.bucket=my-platforma-bucket \
  --set storage.main.gcs.projectId=my-project
```

**Generic NFS:**
```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 \
  -n platforma \
  --set storage.workspace.nfs.enabled=true \
  --set storage.workspace.nfs.server=nfs.example.com \
  --set storage.workspace.nfs.path=/exports/platforma
```

## Configuration

See [values.yaml](charts/platforma/values.yaml) for all options.

### Storage

Platforma requires three storage areas:

| Area | Type | Description |
|------|------|-------------|
| Database | RWO | RocksDB state. Fast SSD recommended (gp3, pd-ssd). |
| Workspace | **RWX** | Shared job data. EFS, Filestore, or NFS. |
| Main | RWO or S3/GCS | Result storage exposed to Desktop App. |

### Workspace storage

The workspace is shared between the Platforma server pod and all job pods. It **must** be RWX (ReadWriteMany). Configure exactly one option:

| Option | Use case |
|--------|----------|
| `storage.workspace.pvc` | **Recommended for EFS.** Generic RWX PVC via StorageClass. |
| `storage.workspace.existingClaim` | Pre-created RWX PVC |
| `storage.workspace.efs` | AWS EFS (static PV, chart creates PV+PVC) |
| `storage.workspace.filestore` | GCP Filestore |
| `storage.workspace.fsxLustre` | AWS FSx for Lustre (high-performance) |
| `storage.workspace.azureFiles` | Azure Files |
| `storage.workspace.nfs` | Generic NFS server |

#### File ownership and permissions

Platforma runs as a non-root user (UID 1010, GID 1010 by default). The workspace must be writable by this user. How to achieve this depends on the storage type:

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

The EFS Access Point enforces UID/GID 1010 for all file operations, so no init container is needed. This is the simplest and most reliable approach.

**AWS FSx for Lustre — use `chownOnInit`**

FSx Lustre has no Access Point concept. The filesystem root is always owned by root. Enable `chownOnInit` to run an init container that changes ownership before the server starts:

```yaml
storage:
  workspace:
    fsxLustre:
      enabled: true
      fileSystemId: fs-0123456789abcdef
      dnsName: fs-0123456789abcdef.fsx.eu-central-1.amazonaws.com
      mountName: abcdefgh
      path: "/platforma"    # Subdirectory on Lustre filesystem
    chownOnInit: true        # Required for FSx Lustre
```

The `path` field is important — the init container only changes ownership of this subdirectory, not the entire Lustre filesystem. All job mounts use the same path prefix, so files are accessible across pods.

Note: FSx Lustre requires the `lustre-client` package on all nodes. EKS AL2023 AMI does not include it by default — see the [AWS infrastructure guide](infrastructure/aws/) for installation steps.

**GCP Filestore / Generic NFS — typically works without extra configuration**

Filestore and NFS servers can usually be configured at the server level to set the default UID/GID. If your NFS export is owned by root, use `chownOnInit: true`.

**Performance comparison (tested on AWS):**

| Storage | Write throughput | Notes |
|---------|-----------------|-------|
| EFS | 30-45 MB/s | Consistent, scales with file count |
| FSx Lustre | 65-275 MB/s | Higher throughput, varies by instance type |

### Main storage (desktop app access)

The main storage is where Platforma stores results that the Desktop App downloads:

| Type | When to use | Desktop App access |
|------|-------------|-------------------|
| `s3` | AWS deployments | Direct to S3 |
| `gcs` | GCP deployments | Direct to GCS |

The Desktop App accesses cloud storage directly — you only need the gRPC ingress for API connectivity.

### Authentication

Platforma supports optional authentication. Disabled by default.

**htpasswd (file-based):**

```yaml
auth:
  enabled: true
  htpasswd:
    enabled: true
    secretName: "platforma-htpasswd"  # kubectl create secret generic platforma-htpasswd --from-file=htpasswd=./htpasswd
```

**LDAP (direct bind):**

```yaml
auth:
  enabled: true
  ldap:
    enabled: true
    server: "ldap://ldap.example.com:389"
    bindDN: "cn=%u,ou=users,dc=example,dc=com"  # %u = username
```

**LDAP (search bind):**

```yaml
auth:
  enabled: true
  ldap:
    enabled: true
    server: "ldap://ldap.example.com:389"
    searchRules:
      - "(uid=%s)|ou=users,dc=example,dc=com"
    searchUser: "cn=readonly,dc=example,dc=com"
    searchPasswordSecretRef:
      name: "ldap-search-password"
      key: "password"
```

See [values.yaml](charts/platforma/values.yaml) `auth` section for TLS, CA certificates, and client certificate options.

### Networking

Platforma exposes a gRPC API on port 6345. The Desktop App connects here for all operations. When using S3 or GCS main storage, the Desktop App downloads results directly from the cloud — no additional ingress is needed.

The chart generates Ingress resources from `ingress` and `additionalIngress` blocks. Each block has `api` (gRPC) and `data` (HTTP) sub-sections with independent annotations.

#### AWS ALB Ingress Controller

The [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) creates an ALB per Ingress resource by default. To share a single ALB between Platforma and other services in the cluster, use the `group.name` annotation:

```yaml
ingress:
  enabled: true
  className: alb

  api:
    host: "platforma.example.com"
    annotations:
      alb.ingress.kubernetes.io/group.name: "shared"
      alb.ingress.kubernetes.io/group.order: "100"
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/backend-protocol-version: GRPC
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

  api:
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

  api:
    host: "platforma.example.com"
    tls:
      enabled: true
      secretName: "platforma-tls"
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      traefik.ingress.kubernetes.io/service.serversscheme: h2c
```

#### LoadBalancer service (no ingress)

For simpler setups without an ingress controller:

```yaml
service:
  type: LoadBalancer
  annotations:
    # AWS NLB example:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
```

This exposes the raw gRPC port. The Desktop App connects to `<lb-address>:6345`. No TLS termination — configure TLS in Platforma directly or accept unencrypted connections.

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

```yaml
logging:
  # Default: logs to container stderr (use kubectl logs)
  destination: "stream://stderr"

  # Alternative: logs to persistent volume with rotation
  # destination: "dir:///var/log/platforma"
  # rotation:
  #   size: 1Gi     # Max size per log file
  #   count: 15     # Number of rotated files to keep
```

When using `dir://` destination, enable the logs PVC:

```yaml
storage:
  logs:
    enabled: true
    size: 10Gi
```

### Monitoring

```yaml
monitoring:
  enabled: true   # Exposes /metrics on port 9090
  podMonitoring:
    enabled: true   # GKE PodMonitoring resource (for GMP)
    interval: 30s
```

For Prometheus on AWS/generic clusters, scrape the metrics service directly or add annotations.

### Kueue modes

| Mode | Description |
|------|-------------|
| `dedicated` (default) | Chart creates ClusterQueues, LocalQueues, ResourceFlavors |
| `shared` | Chart references pre-existing Kueue resources |

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

Mount external read-only data (reference genomes, sequencing archives) accessible to Platforma:

```yaml
dataSources:
  - name: "reference-genomes"
    type: s3
    s3:
      bucket: "company-references"
      region: "eu-central-1"
  - name: "local-data"
    type: pvc
    pvc:
      existingClaim: "shared-data-pvc"
```

### Extra CLI arguments

Additional Platforma CLI arguments can be passed via `extraArgs`. See [values.yaml](charts/platforma/values.yaml) for examples.

## Upgrade

```bash
helm upgrade platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 -n platforma -f your-values.yaml
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
