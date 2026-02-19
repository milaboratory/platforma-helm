# HPC/Slurm infrastructure setup for Platforma

Deploy Platforma on an existing Slurm cluster using [interLink](https://github.com/interlink-hq/interLink) to bridge Kubernetes pods to Slurm jobs. Slurm handles all scheduling, queuing, and resource management — no Kueue or AppWrapper needed.

## Architecture

```
┌─────────────────────────────────┐       ┌────────────────────────────────────────┐
│  K8S Cluster (Control Plane)    │       │  Slurm Cluster                         │
│                                 │       │                                        │
│  ┌───────────────────────────┐  │       │  ┌──────────────────────────────────┐  │
│  │  Platforma Backend Pod    │  │       │  │  Head Node                       │  │
│  │  creates Pods with:       │  │       │  │                                  │  │
│  │  - nodeSelector: vnode    │  │       │  │  interLink API Server (:3000)    │  │
│  │  - slurm annotations     │  │       │  │         │ Unix socket             │  │
│  └──────────┬────────────────┘  │       │  │  interLink SLURM Plugin          │  │
│             │ K8S API           │       │  │         │ sbatch/squeue/scancel   │  │
│  ┌──────────▼────────────────┐  │       │  │  slurmctld (scheduler)           │  │
│  │  interLink VirtualKubelet │  │ HTTPS │  │                                  │  │
│  │  registers virtual node   │──┼───────┼──▶                                  │  │
│  │  polls status every 5s    │◀─┼───────┼──│                                  │  │
│  └───────────────────────────┘  │       │  └────────────────┬─────────────────┘  │
│                                 │       │                   │                     │
│  No Kueue — Slurm is the      │       │  ┌───────────────▼───────────────────┐  │
│  scheduler for this path       │       │  │  Compute Nodes                    │  │
│                                 │       │  │  slurmd + Apptainer + GPUs       │  │
│                                 │       │  └───────────────┬───────────────────┘  │
└─────────────────────────────────┘       │                   │                     │
                                          └───────────────────┼─────────────────────┘
                                                    ┌─────────▼──────────┐
                                                    │  Shared Filesystem │
                                                    │  NFS / Lustre /    │
                                                    │  BeeGFS / GPFS     │
                                                    └────────────────────┘
```

**How it works:** Platforma creates K8S pods with Slurm annotations. The VirtualKubelet routes them to the interLink API server on the Slurm head node, which translates them to `sbatch` commands. Compute nodes run containers via Apptainer. Status is polled via `squeue` every 5 seconds.

## Deployment paths

| Path | Root on HPC? | K8S cluster | Best for |
|------|-------------|-------------|----------|
| **[User-level (SSH tunnel)](user-deployment.md)** | No | K3S on your workstation | Individual researchers, no admin involvement |
| **Root-based (this guide)** | Yes (on head node) | Any (EKS, GKE, K3S) | Institutional deployments, dedicated VMs |

For user-level deployment without root, see **[user-deployment.md](user-deployment.md)**.

---

## Prerequisites

- **Kubernetes cluster** (EKS, GKE, K3S, or any) with Helm v3.12+
- **Slurm cluster** with slurmctld running (tested with Ubuntu 24.04 `slurm-wlm` package)
- **Apptainer** v1.3+ on all Slurm compute nodes
- **Shared filesystem** (NFS, Lustre, BeeGFS, or GPFS) mounted on Slurm head + all compute nodes
- **Network connectivity** from K8S cluster to Slurm head node on port 3000

## Files in this directory

| File | Description |
|------|-------------|
| `user-deployment.md` | User-level deployment guide (SSH tunnel, no root on HPC) |
| `values-slurm-example.yaml` | Platforma Helm values for Slurm/interLink integration |

---

## Step 1: Verify Slurm cluster

Ensure your Slurm cluster is healthy before starting interLink setup.

```bash
# On Slurm head node:
sinfo                              # All partitions should be UP
srun --partition=batch hostname    # Should return a worker hostname
```

### Required slurm.conf directives

```conf
SlurmUser=slurm              # slurmctld runs as slurm user
SlurmdUser=root              # slurmd needs root for cgroups
AuthType=auth/munge          # Primary auth between nodes
StateSaveLocation=/var/spool/slurm/statesave
ReturnToService=1            # Nodes re-register after slurmctld restart
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity
```

### Required cgroup.conf (for memory limit enforcement)

```conf
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes
```

Without `ConstrainRAMSpace=yes`, Slurm does not enforce `--mem` limits and OOM detection will not work.

### Permissions

```bash
# State dirs owned by slurm user (on all nodes)
chown -R slurm:slurm /var/spool/slurm /var/log/slurm

# JWT key (on head node, if using slurmrestd)
chown slurm:slurm /var/spool/slurm/statesave/jwt_hs256.key
chmod 0600 /var/spool/slurm/statesave/jwt_hs256.key

# Munge key identical on ALL nodes
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
```

If setting up Slurm from scratch, see the Slurm documentation for the complete order of operations (`slurm.conf`, `cgroup.conf`, munge key distribution, partition setup).

---

## Step 2: Install Apptainer on compute nodes

Apptainer (formerly Singularity) runs Docker images on Slurm compute nodes.

```bash
# On each compute node:
wget -qO /tmp/apptainer.deb \
    "https://github.com/apptainer/apptainer/releases/download/v1.3.6/apptainer_1.3.6_amd64.deb"
apt-get install -y -qq /tmp/apptainer.deb
rm -f /tmp/apptainer.deb

# Verify
apptainer version    # 1.3.6
```

Docker images are auto-converted on first pull (`docker://image:tag` to SIF format, ~6s). Cached after first pull.

---

## Step 3: Install interLink on Slurm head node

interLink v0.6.0 consists of two binaries on the Slurm head: an API server and a SLURM plugin.

### Download binaries

```bash
INTERLINK_VERSION="0.6.0"
mkdir -p /root/.interlink/{logs,bin,config}

wget -q -O /root/.interlink/bin/interlink \
    "https://github.com/interlink-hq/interLink/releases/download/${INTERLINK_VERSION}/interlink_Linux_x86_64"
chmod +x /root/.interlink/bin/interlink

wget -q -O /root/.interlink/bin/interlink-sidecar-slurm \
    "https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/${INTERLINK_VERSION}/interlink-sidecar-slurm_Linux_x86_64"
chmod +x /root/.interlink/bin/interlink-sidecar-slurm
```

### API server config

```yaml
# /root/.interlink/config/InterLinkConfig.yaml
InterlinkAddress: "http://0.0.0.0"    # Use HTTPS + OAuth2 in production
InterlinkPort: "3000"
SidecarURL: "unix:///root/.interlink/.plugin.sock"
SidecarPort: "0"
VerboseLogging: true
ErrorsOnlyLogging: false
```

### SLURM plugin config

```yaml
# /root/.interlink/config/SlurmConfig.yaml
SidecarPort: "0"
Socket: "unix:///root/.interlink/.plugin.sock"
SbatchPath: "/usr/bin/sbatch"
ScancelPath: "/usr/bin/scancel"
SqueuePath: "/usr/bin/squeue"
SinfoPath: "/usr/bin/sinfo"
CommandPrefix: ""
ImagePrefix: "docker://"
SingularityPath: "/usr/bin/apptainer"    # NOT /usr/bin/singularity
ExportPodData: true
DataRootFolder: "/shared/interlink/"     # Must be on shared filesystem
Namespace: "platforma"                    # Must match Platforma release namespace
BashPath: /bin/bash
VerboseLogging: true
ErrorsOnlyLogging: false
EnableProbes: true
```

**Key settings:**
- `SingularityPath` — use `/usr/bin/apptainer` (Ubuntu 24.04 creates a `/usr/bin/singularity` symlink, but use the real binary)
- `DataRootFolder` — **must** be on the shared filesystem (NFS/Lustre) accessible from all compute nodes
- `Namespace` — must match the Kubernetes namespace where VirtualKubelet creates pods

### Systemd services

Create `/etc/systemd/system/interlink-slurm-plugin.service`:

```ini
[Unit]
Description=interLink SLURM Plugin
After=munge.service
Requires=munge.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/.interlink
Environment="SLURMCONFIGPATH=/root/.interlink/config/SlurmConfig.yaml"
ExecStart=/root/.interlink/bin/interlink-sidecar-slurm
Restart=on-failure
RestartSec=5
StandardOutput=append:/root/.interlink/logs/slurm-plugin.log
StandardError=append:/root/.interlink/logs/slurm-plugin.log

[Install]
WantedBy=multi-user.target
```

Create `/etc/systemd/system/interlink.service`:

```ini
[Unit]
Description=interLink API Server
After=network.target interlink-slurm-plugin.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/.interlink
Environment="INTERLINKCONFIGPATH=/root/.interlink/config/InterLinkConfig.yaml"
ExecStart=/root/.interlink/bin/interlink
Restart=on-failure
RestartSec=5
StandardOutput=append:/root/.interlink/logs/interlink.log
StandardError=append:/root/.interlink/logs/interlink.log

[Install]
WantedBy=multi-user.target
```

**Start order:** Plugin first (creates the Unix socket), then API server.

```bash
systemctl daemon-reload
systemctl enable --now interlink-slurm-plugin
sleep 2
systemctl enable --now interlink
sleep 2

# Verify
curl -sf http://localhost:3000/pinglink && echo "OK" || echo "FAILED"
```

---

## Step 4: Deploy VirtualKubelet on K8S cluster

The VirtualKubelet registers a virtual node in Kubernetes that routes pods to Slurm.

### Create interLink values

```yaml
# interlink-values.yaml
nodeName: slurm-virtual-node

interlink:
  enabled: false          # Remote mode — API server runs on Slurm head, not in K8S
  address: http://SLURM_HEAD_IP   # Replace with Slurm head node IP/hostname
  port: 3000
  disableProjectedVolumes: true

virtualNode:
  image: ghcr.io/interlink-hq/interlink/virtual-kubelet-inttw:0.6.0
  resources:
    CPUs: 4               # Advertised capacity — set to sum of compute node CPUs
    memGiB: 7             # Advertised capacity — set to sum of compute node memory
    pods: 100
  HTTP:
    insecure: true         # Set to false and configure OAuth2 for production
  kubeletHTTP:
    insecure: true

OAUTH:
  enabled: false           # Enable for production
```

### Deploy

```bash
helm upgrade --install --create-namespace -n interlink-system slurm-virtual-node \
    oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink \
    --version 0.6.0 \
    --values interlink-values.yaml
```

### Verify

```bash
kubectl get nodes
# Should show: slurm-virtual-node   Ready   agent   ...
```

---

## Step 5: Create license secret

```bash
kubectl create namespace platforma

kubectl create secret generic platforma-license \
  -n platforma \
  --from-literal=MI_LICENSE="your-license-key"
```

---

## Step 6: Install Platforma

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 \
  -n platforma \
  -f values-slurm-example.yaml \
  --set storage.workspace.nfs.server=YOUR_NFS_SERVER \
  --set storage.workspace.nfs.path=/exports/platforma/workspace
```

Verify:

```bash
kubectl get pods -n platforma
kubectl get pvc -n platforma
kubectl get nodes   # Should show slurm-virtual-node
```

---

## Verification checklist

```bash
echo "=== Virtual Node ==="
kubectl get nodes

echo ""
echo "=== Platforma ==="
kubectl get pods -n platforma
kubectl get pvc -n platforma

echo ""
echo "=== interLink (on Slurm head) ==="
# Run on Slurm head node:
# systemctl status interlink interlink-slurm-plugin
# curl -sf http://localhost:3000/pinglink && echo "OK"

echo ""
echo "=== Test Job ==="
# Submit a test pod to verify the full pipeline:
kubectl run test-slurm \
  --image=docker://alpine:3.19 \
  --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"slurm-virtual-node"},"tolerations":[{"key":"virtual-node.interlink/no-schedule","operator":"Exists"}]}}' \
  -- echo "Hello from Slurm"

sleep 30
kubectl get pod test-slurm   # Should be Succeeded
kubectl delete pod test-slurm
```

---

## How it works

1. Platforma creates a Pod with `nodeSelector: slurm-virtual-node` and `slurm-job.vk.io/*` annotations
2. K8S scheduler routes the pod to the VirtualKubelet
3. VK sends a `POST /create` to the interLink API server on the Slurm head
4. API server forwards to the SLURM plugin via Unix socket
5. Plugin generates a batch script and runs `sbatch`
6. Slurm dispatches the job to a compute node
7. Compute node pulls the Docker image via Apptainer and runs the container
8. VK polls `GET /status` every 5 seconds — plugin runs `squeue`
9. Pod status updates: Pending → Running → Succeeded/Failed
10. On cancellation: `kubectl delete pod` → VK → `scancel`

### State mapping

| Slurm state | K8S pod phase | Exit code |
|-------------|---------------|-----------|
| PENDING | Pending | — |
| RUNNING | Running | — |
| COMPLETED (exit 0) | Succeeded | 0 |
| FAILED (exit N) | Failed | N |
| TIMEOUT | Failed | 15 (SIGTERM) |
| OUT_OF_MEMORY | Failed | 137 (SIGKILL) |
| CANCELLED | Deleted | — |

### Comparison with cloud (EKS/GKE) path

| Concern | Cloud path | Slurm path |
|---------|-----------|------------|
| Scheduler | Kueue (K8S-side) | Slurm (HPC-side) |
| Quota management | Kueue ClusterQueues | Slurm partitions + QOS |
| Status detection | AppWrapper `status.phase` | Pod phase + exit code |
| Container runtime | containerd | Apptainer (OCI → SIF) |
| GPU support | K8S device plugin | Slurm `--gres=gpu:N` via annotation |
| Shared storage | EFS / Filestore CSI | NFS / Lustre mount on all nodes |

### Pod annotations (Slurm control plane)

```yaml
annotations:
  # Slurm sbatch flags — partition, time limit, memory, GPUs
  slurm-job.vk.io/flags: "--partition=gpu --time=04:00:00 --mem=32G --gres=gpu:1"

  # Apptainer bind mounts — required for shared filesystem access
  slurm-job.vk.io/singularity-mounts: "--bind /shared:/shared"
```

Pod resource limits map to Slurm:
- `resources.limits.cpu` → `--cpus-per-task`
- `resources.limits.memory` → `--mem` (converted to MB)

**Without explicit resource limits, interLink defaults to 1 CPU / 1MB — always set limits.**

---

## Production considerations

### Security: OAuth2 + HTTPS

The insecure HTTP configuration above is for testing only. For production:

1. Configure TLS on the interLink API server (see [interLink docs](https://github.com/interlink-hq/interLink))
2. Enable OAuth2 in both the API server config and VirtualKubelet Helm values
3. Update the VK values to `HTTP.insecure: false` and provide OAuth2 credentials

### Shared filesystem layout

**The workspace must be the same physical storage for both K8S and Slurm.** Platforma server writes job inputs and reads outputs from the workspace PVC. Jobs on Slurm compute nodes read/write the same paths via Apptainer bind mounts. If these point to different storage, jobs will fail with missing files.

| Path | Purpose | Required by | How it's accessed |
|------|---------|-------------|-------------------|
| `/shared/interlink/` | interLink job data (scripts, logs, status files) | SLURM plugin + compute nodes | Direct mount on Slurm nodes |
| `/shared/workspace/` | Platforma job working directories (input/output) | Platforma server + compute nodes | K8S: NFS PVC. Slurm: bind mount via `slurm.bindMounts` |
| `/shared/references/` | Data libraries (read-only) | Compute nodes | Direct mount on Slurm nodes |

**Admin setup:** Make the HPC shared filesystem available to the K8S cluster as an NFS PV/PVC (or mount it on the K3S node and use hostPath). The Slurm bind mount and the K8S workspace PVC must resolve to the same directory:

```yaml
# Helm values — workspace via NFS
storage:
  workspace:
    nfs:
      enabled: true
      server: "nfs-server.internal"
      path: "/shared/workspace"

# Slurm bind mount — same path inside the container
slurm:
  bindMounts: "--bind /shared/workspace:/data/workspace"
```

If the K8S cluster runs on a VM adjacent to the Slurm cluster (recommended), the admin can mount the shared FS directly on the VM and expose it as a hostPath PV instead of NFS.

### Apptainer image cache

Set a shared cache directory so all compute nodes reuse pulled images:

```ini
# In /etc/systemd/system/interlink-slurm-plugin.service [Service] section, add:
Environment="APPTAINER_CACHEDIR=/shared/apptainer-cache"
```

Without this, each compute node independently pulls and converts Docker images to SIF format (~30-60s for large bioinformatics images). With a shared cache, only the first worker pays this cost.

### Private image registries

K8S `imagePullSecrets` do not apply to Slurm jobs. Apptainer handles authentication separately. If your images require authentication:

```ini
# In /etc/systemd/system/interlink-slurm-plugin.service [Service] section, add:
Environment="APPTAINER_DOCKER_USERNAME=<user>"
Environment="APPTAINER_DOCKER_PASSWORD=<token>"
```

### Job data cleanup

interLink stores job data in `DataRootFolder` (`/shared/interlink/`). This accumulates over time. Set up periodic cleanup:

```bash
# Cron job on Slurm head — remove job data older than 7 days
0 2 * * * find /shared/interlink/ -maxdepth 1 -type d -name 'interlink-*' -mtime +7 -exec rm -rf {} +
```

---

## Troubleshooting

### VirtualKubelet not Ready

```bash
kubectl get nodes
kubectl describe node slurm-virtual-node
kubectl logs -n interlink-system -l app=interlink-virtual-kubelet --tail=50
```

Common cause: interLink API server unreachable. Verify from K8S:
```bash
kubectl run --rm -it test-conn --image=curlimages/curl -- curl -sf http://SLURM_HEAD_IP:3000/pinglink
```

### Pods stuck in Pending

```bash
# Check pod events
kubectl describe pod <pod-name>

# On Slurm head, check interLink logs
tail -50 /root/.interlink/logs/interlink.log
tail -50 /root/.interlink/logs/slurm-plugin.log

# Check Slurm queue
squeue -a
sinfo
```

### Job fails with exit code 137 (OOM)

Slurm enforced the `--mem` limit. Either increase the memory limit in pod spec or enable `ConstrainRAMSpace=yes` in `cgroup.conf` to ensure accurate enforcement.

### Munge authentication errors

```bash
# "cred_verify: credential replayed" or similar
# Munge keys are different between nodes. Redistribute head's key:
scp /etc/munge/munge.key root@worker-ip:/etc/munge/munge.key
# On worker:
chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key
systemctl restart munge
```

### `kubectl logs` not working for Slurm pods

The VirtualKubelet CSR may not be auto-approved. This does **not** affect pod lifecycle — only log retrieval.

```bash
kubectl get csr
kubectl certificate approve <csr-name>
```

### Workers stuck in DOWN state

```bash
# After config changes or slurmctld restart
scontrol update nodename=worker-1 state=idle
```

---

## Cleanup

```bash
# Delete Platforma
helm uninstall platforma -n platforma

# Delete VirtualKubelet
helm uninstall slurm-virtual-node -n interlink-system

# On Slurm head: stop interLink services
systemctl stop interlink interlink-slurm-plugin
systemctl disable interlink interlink-slurm-plugin
rm -rf /root/.interlink
```
