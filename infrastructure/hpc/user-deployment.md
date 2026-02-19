# User-level HPC deployment (no root required)

Deploy Platforma on an HPC cluster as a regular user. No root access, no admin involvement.

This guide covers the **SSH tunnel approach** (recommended). See [Alternative: K3S rootless](#alternative-k3s-rootless-on-hpc-login-node) at the end if you need everything on the HPC login node without a workstation.

## Architecture: SSH tunnel

K3S + Platforma run on your workstation. Only the lightweight SLURM plugin runs on the HPC login node.

```
Your workstation                             HPC login node (as regular user)
┌──────────────────────────┐                ┌──────────────────────────────┐
│  K3S (rootful)           │                │  SLURM plugin (:4000)        │
│    ├─ Platforma server   │                │    ├─ calls sbatch/squeue    │
│    ├─ VirtualKubelet     │                │    │  as your user account   │
│    └─ interLink API      │                │    └─ DataRootFolder on      │
│       └─ connects to ────┼── SSH tunnel ──┼───→   shared filesystem     │
│          localhost:4000   │                └──────────────────────────────┘
└──────────────────────────┘                         │
                                                     ↓ sbatch
                                               Slurm cluster
                                               (jobs run as your user)
```

**Why this approach:**
- Minimal HPC footprint (~10 MB binary + tmux/screen session)
- No root on HPC, no admin involvement
- Firewall-friendly (outbound SSH only)
- Officially supported by interLink

**Trade-off:** Your workstation must be running. Mitigate with `autossh` for reconnection.

---

## Critical: shared workspace storage

Platforma server writes job inputs and reads outputs from a **workspace** directory. Jobs on HPC compute nodes read/write the same paths. Both sides must access the **same underlying storage**.

In the SSH tunnel architecture, the server runs on your workstation and jobs run on HPC — different machines, different filesystems. To bridge them, mount the HPC shared filesystem on your workstation via SSHFS:

```
Your workstation                              HPC
┌──────────────────────────────┐             ┌──────────────────────────┐
│  SSHFS mount:                │   SSH       │  /scratch/$USER/         │
│  /mnt/hpc-workspace ────────────────────────→  workspace/            │
│      ↑                       │             │      ↑                  │
│  K3S workspace PVC           │             │  Apptainer bind mount   │
│  (local-path provisioner)    │             │  → /data/workspace      │
└──────────────────────────────┘             └──────────────────────────┘
```

**Setup:**

```bash
# 1. Mount HPC shared FS on workstation
mkdir -p /mnt/hpc-workspace
sshfs user@hpc-login.university.edu:/scratch/$USER/workspace /mnt/hpc-workspace \
    -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3

# 2. Create a PV + PVC pointing to the SSHFS mount
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: hpc-workspace-pv
spec:
  capacity:
    storage: 500Gi
  accessModes: [ReadWriteMany]
  hostPath:
    path: /mnt/hpc-workspace
    type: Directory
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hpc-workspace-pvc
  namespace: platforma
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: hpc-workspace-pv
  resources:
    requests:
      storage: 500Gi
EOF
```

Then in your Platforma Helm values:

```yaml
storage:
  workspace:
    existingClaim: "hpc-workspace-pvc"
```

And the Slurm bind mount maps the same HPC path into the container:

```yaml
slurm:
  bindMounts: "--bind /scratch/$USER/workspace:/data/workspace"
```

Both sides now read/write the same files on `/scratch/$USER/workspace`.

**Alternative:** If your HPC exports NFS (check with `showmount -e hpc-login`), you can use the chart's built-in NFS workspace option instead of SSHFS, which is more stable:

```yaml
storage:
  workspace:
    nfs:
      enabled: true
      server: "hpc-login.university.edu"
      path: "/scratch/$USER/workspace"
```

---

## Prerequisites

| Requirement | Where | Notes |
|-------------|-------|-------|
| K3S or Docker Desktop | Workstation | K3S recommended, Docker Desktop also works |
| Helm v3.12+ | Workstation | For deploying Platforma chart |
| SSH access to HPC login node | Workstation → HPC | Standard SSH key-based auth |
| SSHFS or NFS access to HPC shared FS | Workstation | For workspace storage (see above) |
| Slurm user account | HPC | Regular user account with sbatch access |
| Apptainer on compute nodes | HPC | Usually pre-installed on HPC systems |
| Shared filesystem | HPC | `/scratch/$USER` or similar, accessible from all compute nodes |

---

## Step 1: Set up SLURM plugin on HPC login node

SSH to your HPC login node. Everything runs as your regular user — no `sudo` needed.

### Download plugin

```bash
mkdir -p ~/.interlink/{config,jobs,bin,logs}

# Download SLURM plugin binary
INTERLINK_VERSION="0.6.0"
wget -qO ~/.interlink/bin/interlink-sidecar-slurm \
    "https://github.com/interlink-hq/interlink-slurm-plugin/releases/download/${INTERLINK_VERSION}/interlink-sidecar-slurm_Linux_x86_64"
chmod +x ~/.interlink/bin/interlink-sidecar-slurm
```

### Configure SLURM plugin

```yaml
# ~/.interlink/config/SlurmConfig.yaml
SidecarPort: "4000"
SbatchPath: "/usr/bin/sbatch"
ScancelPath: "/usr/bin/scancel"
SqueuePath: "/usr/bin/squeue"
SinfoPath: "/usr/bin/sinfo"
SingularityPath: "/usr/bin/apptainer"
ImagePrefix: "docker://"
DataRootFolder: "/scratch/$USER/interlink/jobs/"
ExportPodData: true
Namespace: "platforma"
BashPath: /bin/bash
VerboseLogging: true
ErrorsOnlyLogging: false
EnableProbes: true
CommandPrefix: "export APPTAINER_CACHEDIR=/scratch/$USER/.apptainer/cache"
# DO NOT set DefaultUID — requires root for sbatch --uid
```

**Adjust paths for your HPC:**
- `SbatchPath` / `ScancelPath` / etc. — run `which sbatch` to find the correct path
- `SingularityPath` — use `which apptainer` (or `which singularity` on older systems)
- `DataRootFolder` — must be on shared filesystem accessible from all compute nodes
- `CommandPrefix` — set `APPTAINER_CACHEDIR` on shared FS so all workers share cached images

### Start the plugin

```bash
# Run in tmux/screen (persists after SSH disconnect)
tmux new-session -d -s interlink \
    'SLURMCONFIGPATH=~/.interlink/config/SlurmConfig.yaml ~/.interlink/bin/interlink-sidecar-slurm'

# Verify it's running
tmux list-sessions    # Should show "interlink"
curl -sf http://localhost:4000/healthz && echo "OK" || echo "FAILED"
```

To check logs later:

```bash
tmux attach -t interlink    # Ctrl-B D to detach
```

---

## Step 2: Set up SSH tunnel from workstation

On your workstation, create a persistent SSH tunnel that forwards the SLURM plugin port:

```bash
# Simple SSH tunnel (manual reconnect on disconnect)
ssh -N -L 4000:localhost:4000 user@hpc-login.university.edu &

# Production: use autossh for automatic reconnection
autossh -M 0 -f -N -L 4000:localhost:4000 \
    -o "ServerAliveInterval=30" \
    -o "ServerAliveCountMax=3" \
    user@hpc-login.university.edu
```

Verify the tunnel:

```bash
curl -sf http://localhost:4000/healthz && echo "Tunnel OK" || echo "Tunnel FAILED"
```

---

## Step 3: Install interLink API server on workstation

The API server bridges VirtualKubelet to the SLURM plugin (via the SSH tunnel).

### Download binary

```bash
INTERLINK_VERSION="0.6.0"

# macOS
wget -qO /usr/local/bin/interlink \
    "https://github.com/interlink-hq/interLink/releases/download/${INTERLINK_VERSION}/interlink_Darwin_x86_64"
# Linux
# wget -qO /usr/local/bin/interlink \
#     "https://github.com/interlink-hq/interLink/releases/download/${INTERLINK_VERSION}/interlink_Linux_x86_64"

chmod +x /usr/local/bin/interlink
```

### Configure API server

```yaml
# ~/.interlink/InterLinkConfig.yaml
InterlinkAddress: "http://0.0.0.0"
InterlinkPort: "3000"
SidecarURL: "http://localhost:4000"
VerboseLogging: true
ErrorsOnlyLogging: false
```

The API server connects to `localhost:4000` which is forwarded to the HPC plugin via SSH tunnel.

### Start API server

```bash
INTERLINKCONFIGPATH=~/.interlink/InterLinkConfig.yaml interlink &

# Verify
curl -sf http://localhost:3000/pinglink && echo "OK" || echo "FAILED"
```

---

## Step 4: Install K3S and deploy VirtualKubelet

### Install K3S (if not already installed)

```bash
# macOS: use Docker Desktop or Rancher Desktop with K3S
# Linux:
curl -sfL https://get.k3s.io | sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

### Deploy VirtualKubelet

```yaml
# interlink-values.yaml
nodeName: slurm-virtual-node

interlink:
  enabled: false
  address: http://host.docker.internal    # or http://localhost if K3S is native
  port: 3000
  disableProjectedVolumes: true

virtualNode:
  image: ghcr.io/interlink-hq/interlink/virtual-kubelet-inttw:0.6.0
  resources:
    CPUs: 4               # Set to your HPC allocation (sinfo to check)
    memGiB: 7             # Set to your HPC allocation
    pods: 100
  HTTP:
    insecure: true
  kubeletHTTP:
    insecure: true

OAUTH:
  enabled: false
```

**Note on `interlink.address`:**
- Docker Desktop K8S: use `http://host.docker.internal`
- Native K3S on Linux: use `http://localhost`
- The VK pod needs to reach the interLink API server on your workstation

```bash
helm upgrade --install --create-namespace -n interlink-system slurm-virtual-node \
    oci://ghcr.io/interlink-hq/interlink-helm-chart/interlink \
    --version 0.6.0 \
    --values interlink-values.yaml
```

Verify:

```bash
kubectl get nodes
# Should show: slurm-virtual-node   Ready   agent   ...
```

---

## Step 5: Install Platforma

```bash
kubectl create namespace platforma

kubectl create secret generic platforma-license \
    -n platforma \
    --from-literal=MI_LICENSE="your-license-key"

helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
    --version 3.0.0 \
    -n platforma \
    -f values-slurm-example.yaml
```

---

## Verification

```bash
echo "=== Virtual Node ==="
kubectl get nodes

echo ""
echo "=== Platforma ==="
kubectl get pods -n platforma

echo ""
echo "=== SSH tunnel ==="
curl -sf http://localhost:4000/healthz && echo "SLURM plugin reachable" || echo "TUNNEL DOWN"
curl -sf http://localhost:3000/pinglink && echo "API server OK" || echo "API server DOWN"

echo ""
echo "=== Test job ==="
kubectl run test-slurm \
    --image=docker://alpine:3.19 \
    --restart=Never \
    --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"slurm-virtual-node"},"tolerations":[{"key":"virtual-node.interlink/no-schedule","operator":"Exists"}]}}' \
    -- echo "Hello from Slurm"

sleep 30
kubectl get pod test-slurm
kubectl delete pod test-slurm
```

---

## Running processes overview

| Process | Where | How to manage |
|---------|-------|---------------|
| SLURM plugin | HPC login node | `tmux attach -t interlink` |
| SSH tunnel | Workstation (background) | `autossh` or manual `ssh -N -L` |
| interLink API server | Workstation (background) | `kill` or wrap in launchd/systemd |
| K3S | Workstation | `systemctl status k3s` or Docker Desktop |

---

## Troubleshooting

### SSH tunnel dropped

```bash
# Check if tunnel is alive
curl -sf http://localhost:4000/healthz

# If using autossh, it reconnects automatically
# If using manual ssh, restart:
ssh -N -L 4000:localhost:4000 user@hpc-login.university.edu &
```

### SLURM plugin not running on HPC

```bash
# SSH to HPC
tmux attach -t interlink    # Check if session exists
# If not, restart:
tmux new-session -d -s interlink \
    'SLURMCONFIGPATH=~/.interlink/config/SlurmConfig.yaml ~/.interlink/bin/interlink-sidecar-slurm'
```

### Jobs fail with permission errors

Do NOT set `DefaultUID` in `SlurmConfig.yaml` — it requires root for `sbatch --uid`. Without it, all jobs run as your user account, which is the correct behavior for user-level deployment.

### Image pull failures on compute nodes

```bash
# Verify Apptainer works as your user
srun apptainer exec docker://alpine:3.19 echo "OK"

# If cache is slow, pre-pull on shared FS
export APPTAINER_CACHEDIR=/scratch/$USER/.apptainer/cache
apptainer pull docker://ghcr.io/milaboratory/mixcr:4.7.0
```

---

## Cleanup

```bash
# Workstation
helm uninstall platforma -n platforma
helm uninstall slurm-virtual-node -n interlink-system
kill %interlink    # Stop API server
kill %autossh      # Stop SSH tunnel (or kill the ssh -N process)

# HPC login node
tmux kill-session -t interlink
rm -rf ~/.interlink
rm -rf /scratch/$USER/interlink
```

---

## Alternative: K3S rootless on HPC login node

> **This approach eliminates the workstation dependency** — everything runs on the HPC login node as user processes. However, most HPC systems lack the required kernel features. Check prerequisites carefully before attempting.

### Architecture

```
HPC login node (as regular user)
┌────────────────────────────────────────┐
│  K3S (rootless, systemd --user)        │
│    ├─ Platforma server pod             │
│    └─ VirtualKubelet pod               │
│         └─ connects to localhost:3000  │
│                                        │
│  interLink API server (:3000)          │
│  SLURM plugin (:4000)                  │
│    └─ sbatch/squeue/scancel as user    │
└────────────────────────────────────────┘
         │
         ↓ sbatch
   Slurm cluster
   (jobs run as your user)
```

### Prerequisites (one-time HPC admin involvement)

Most of these are kernel/system settings that only an HPC admin can enable. Run these checks first — if any fail, use the SSH tunnel approach above instead.

```bash
# 1. cgroups v2 — required
stat -fc %T /sys/fs/cgroup
# Must print: cgroup2fs
# If it prints "tmpfs", the system uses cgroups v1 — K3S rootless won't work

# 2. User namespaces — required
cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo "check sysctl"
# Must be: 1
# Many HPC systems disable this for security

# 3. Sub-UID/GID ranges — required
grep $USER /etc/subuid && grep $USER /etc/subgid
# Must show ranges like: username:100000:65536

# 4. systemd --user with linger — required
systemctl --user status
# Must work (not "Failed to connect to bus")
# Admin enables with: sudo loginctl enable-linger $USER

# 5. Required packages (admin installs)
which newuidmap newgidmap    # from uidmap package
which fuse-overlayfs         # rootless overlay filesystem
which slirp4netns            # rootless networking
```

**If any check fails**, ask your HPC admin to enable the missing features, or use the SSH tunnel approach (Steps 1–5 above) which has no such requirements.

### Install K3S rootless

```bash
mkdir -p ~/bin

# Download K3S binary
curl -Lo ~/bin/k3s https://github.com/k3s-io/k3s/releases/latest/download/k3s
chmod +x ~/bin/k3s

# Install the rootless systemd service
mkdir -p ~/.config/systemd/user/
# Download k3s-rootless.service from the K3S repo and place in ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now k3s-rootless

export KUBECONFIG=~/.kube/k3s.yaml
kubectl get nodes    # Should show the local node
```

### Networking caveats

K3S rootless uses `slirp4netns` for networking, which has important differences from normal K3S:

- **No host networking** — pods reach the host via slirp gateway at `10.0.2.2`, not `localhost`
- **Port offset** — ports below 1024 are shifted by +10000 (e.g., port 80 → 10080)
- To allow pods to reach the interLink API server on `localhost:3000`, set `K3S_ROOTLESS_DISABLE_HOST_LOOPBACK=false` in the systemd service, then configure VirtualKubelet to connect to `10.0.2.2:3000`

### Resource usage

K3S rootless consumes ~1.5 GB RAM and ~5% CPU at idle on the shared login node. This may violate your HPC facility's acceptable use policy for login nodes — check with your admin.

### Limitations

- **Multiple users on the same login node**: officially unsupported by K3S rootless
- **Disk I/O**: the rootless overlay filesystem (`fuse-overlayfs`) is slower than native overlayfs
- **Stability**: K3S rootless is less battle-tested than the standard rootful mode

### When to use this approach

Use K3S rootless only if **all** of these are true:
1. Your HPC system passes all prerequisite checks above
2. You need 24/7 availability without a workstation dependency
3. Your HPC admin approves ~1.5 GB RAM usage on the login node
4. A dedicated VM (the most robust option) is not available

Otherwise, the SSH tunnel approach (main guide above) is more reliable and works on any HPC system.
