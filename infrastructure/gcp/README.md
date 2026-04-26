# Platforma on GCP (GKE) — Runbook

A single Infrastructure Manager deployment provisions the full Platforma
stack on GKE: VPC, cluster + auto-scaling node pools, Filestore (SSD), GCS
bucket, Workload Identity, Kueue/AppWrapper, the Platforma Helm release,
plus an HTTPS ingress (Cloud DNS A record + Certificate Manager managed
cert + GKE Gateway). Mirrors the
[AWS CloudFormation runbook](../aws/README.md) in shape.

## Three install paths

| Tier | Audience | How |
|---|---|---|
| **1. Cloud Shell** | Non-IT user, single click | [Open in Cloud Shell](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/milaboratory/platforma-helm&cloudshell_workspace=infrastructure/gcp/cloudshell&cloudshell_tutorial=tutorial.md) — tutorial in side panel, `install.sh` collects ~10 inputs and submits Infrastructure Manager. ~25 min. |
| **2. Local CLI** | DevOps / IT admin | Clone repo, run [`cloudshell/install.sh`](cloudshell/install.sh) from your own terminal. Same script, same result. Pre-fill any prompt with env vars for non-interactive use. |
| **3. Local Terraform** | Power user / CI integration | Clone repo, edit `terraform/terraform.tfvars`, run `tofu apply` against your own GCS state backend. Bypasses Infrastructure Manager — see [`advanced-installation.md`](advanced-installation.md). |

All three share the same Terraform module under [`terraform/`](terraform/).

## Architecture

```
                            ┌──────────────────────────────────────────────┐
                            │       Your GCP project (created by you)      │
                            │                                              │
  Desktop App  ──HTTPS──▶  ┌─┴────────────┐                                │
                            │ GKE Gateway   │  TLS at L7, gRPC to backend  │
                            │ + Cert Mgr    │                              │
                            │ + Cloud DNS   │                              │
                            └─┬────────────┘                               │
                              │                                            │
                              │  internal HTTP/2                           │
                              ▼                                            │
                      ┌──────────────────────┐                             │
                      │  GKE Standard cluster│                             │
                      │   (VPC-native)       │                             │
                      │                      │                             │
                      │  ┌─system pool───┐   │                             │
                      │  │ Platforma srv │   │                             │
                      │  │ Kueue / AppWr │   │  ──ServiceAccount──▶  GCS  │
                      │  └───────────────┘   │     (Workload Identity)    │
                      │  ┌─UI pool────┐      │                             │
                      │  │ scale 0-N  │      │  ──Filestore CSI──▶  Filestore (SSD)
                      │  └────────────┘      │                             │
                      │  ┌─batch pool─┐      │                             │
                      │  │ scale 0-N  │      │                             │
                      │  │ n2d-highmem│      │                             │
                      │  └────────────┘      │                             │
                      └──────────────────────┘                             │
                            │                                              │
                            └──────────────────────────────────────────────┘
```

## Prerequisites

- A GCP project with billing enabled
- Owner role on the project (for the simplest installer flow), OR the
  [fine-grained role set](permissions.md) for production
- A registered domain — see [`domain-guide.md`](domain-guide.md) for setting
  up a Cloud DNS zone (works with Route53, Cloudflare, GoDaddy, etc.)
- A Platforma license key from MiLaboratories
- Local: `gcloud` SDK installed (`brew install --cask google-cloud-sdk`)

## Deployment sizes

`deployment_size` controls node-pool maxes, Kueue batch queue quotas, Filestore
default capacity, and the values the installer requests via the Cloud Quotas
API. **All sizes share the same per-job cap of 62 vCPU / 500 GiB RAM** — the
preset only controls how many such jobs can run in parallel.

| Preset | Parallel jobs | UI nodes max | Filestore (GiB) | CPUs (global) | N2D CPUs (region) | PD SSD GB (region) | Filestore Zonal GiB (region) | Instances (region) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `small`  |  4 |  4 | 1024 |  512 |  512 |  2048 | 1024 |  32 |
| `medium` |  8 |  8 | 2048 | 1024 | 1024 |  4096 | 2048 |  48 |
| `large`  | 16 | 16 | 4096 | 2048 | 2048 |  8192 | 4096 |  64 |
| `xlarge` | 32 | 16 | 8192 | 4096 | 4096 | 16384 | 8192 | 128 |

Larger sizes request larger GCP quotas. The installer auto-submits these via
the Cloud Quotas API on first run; **small/medium** typically auto-approve
in seconds, **xlarge** often needs human review (24-72 h).

If your project already has user-managed quota preferences, the installer
detects them, skips re-requesting (the API rejects duplicate creates), and
warns when an existing value is below the chosen preset's requirement.

## Cost notes

Rough idle cost (no jobs running, Tier-1 small):

| Component | $/hour idle |
|---|---|
| GKE Standard control plane | $0.10 |
| System pool (2× n2d-standard-4) | $0.40 |
| Filestore Zonal 1 TiB | $0.40 |
| Static IP + Cloud DNS records + Cert Manager | ~$0 |
| **Idle total** | **~$0.50/hour (~$360/month)** |

Batch + UI pools scale from zero, so they don't burn when idle. Active jobs
add `n2d-highmem-64` instance-hours (~$3.60/h per running batch node).

GKE control plane is the only fixed cost (~$73/month). Filestore SSD is the
floor — at 1 TiB, ~$300/month. Smaller deployments can drop to BASIC_HDD
(1 TiB, ~$200/month) but our CTO validated this isn't enough I/O for real
bioinformatics workloads — use Zonal SSD for production.

## Authentication

Two methods supported (mirrors the AWS CloudFormation runbook):

- **htpasswd** — file-based local auth.
  - **Auto-generated** (default — `htpasswd_content=""`): the installer
    creates a random admin password and stores it in Secret Manager.
    **TESTING ONLY** — the password ends up in Terraform state.
  - **User-supplied content** (`htpasswd_content` = pre-bcrypted string, or
    `HTPASSWD_FILE=path/to/htpasswd` env var): production-ready single-team
    setup. Generate with `htpasswd -nB <username>`.
- **LDAP** (`auth_method=ldap`) — corporate directory integration. Supports
  direct-bind (template) or search-bind (rules + service-account creds).

## Data libraries

External read-only buckets that hold input data (e.g. fastq files). Without
data libraries, the cluster has no real input data beyond the bundled demo
dataset.

| Type | Same project | Cross-project / cross-cloud |
|---|---|---|
| `gcs` | Workload Identity — grant `platforma-server@<project>.iam.gserviceaccount.com` `roles/storage.objectViewer` on the bucket before installing | HMAC keys for the bucket's project; pass via `access_key`/`secret_key` |
| `s3` | n/a | IAM access keys |

The MiLaboratories **demo data library** (`enable_demo_data_library=true`,
default) mounts MiLab's public S3 bucket cross-cloud — same dataset the AWS
path uses. Disable for production deployments where you don't want it visible
to users.

## Files

- [`terraform/`](terraform/) — Terraform module (root).
  - [`presets.tf`](terraform/presets.tf) — deployment-size lookup table (source of truth).
  - [`variables.tf`](terraform/variables.tf) — full parameter reference.
  - [`terraform.tfvars.example`](terraform/terraform.tfvars.example) — minimal local-dev template.
- [`cloudshell/`](cloudshell/) — Tier-1 quickstart.
  - [`tutorial.md`](cloudshell/tutorial.md) — Cloud Shell walkthrough.
  - [`install.sh`](cloudshell/install.sh) — driver script (also runs standalone outside Cloud Shell).
- [`domain-guide.md`](domain-guide.md) — Cloud DNS zone creation + delegation from external registrars (Route53, Cloudflare, GoDaddy, Namecheap).
- [`permissions.md`](permissions.md) — fine-grained IAM role set replacing `roles/owner` on the deployer SA.
- [`advanced-installation.md`](advanced-installation.md) — Tier-3 local-Terraform path with manual gcloud auth, custom backends, full customization.

## Updates

Re-running `install.sh` (Tier-1 / Tier-2) detects the existing Infrastructure
Manager deployment and creates a new revision. Roll back via the IM Console
**Revisions** tab if needed.

For Tier-3 (local Terraform), edit tfvars and `tofu apply` again.

## Tearing down

Tier-1 / Tier-2:

```bash
gcloud infra-manager deployments delete platforma \
  --location=europe-west1 --project=YOUR_PROJECT --quiet
```

Tier-3: `tofu destroy`.

The primary GCS bucket is **retained** for data safety (Terraform `force_destroy
= false`). To remove it after the deployment is destroyed:

```bash
gcloud storage rm -r gs://platforma-platforma-cluster-XXXXXXXX
```

The Cloud DNS zone you set up in [`domain-guide.md`](domain-guide.md) is **not
managed by this module** — leave it in place if you'll re-deploy.

## Troubleshooting

### Deployment stuck in CREATING for >30 min

Open the IM Console: `https://console.cloud.google.com/infra-manager/deployments?project=YOUR_PROJECT`
and click into the deployment → **Resources** tab to see what's still pending.

If a Cloud Build run failed, follow the link from the Console to read the
Terraform error output.

### `Permission denied` on a specific resource

The deployer service account is missing a role. Match the missing permission
against [`permissions.md`](permissions.md) and add the corresponding role.

### Quota errors during cluster scale-up

Job pods stuck `Pending`, events show `Insufficient cpu` or `quota_exceeded`.
Means the deployment_size you picked needs more quota than your project has.

- If the installer requested it via auto-submission: wait for the email
  approval (small bumps are fast; large ones can take 24-72 h).
- If your project already has user-managed quota preferences below the preset:
  bump them at `https://console.cloud.google.com/iam-admin/quotas?project=YOUR_PROJECT`.

### Cert validation stuck

Run:

```bash
gcloud certificate-manager certificates describe platforma-cluster-cert \
  --location=global --project=YOUR_PROJECT
```

`state: PROVISIONING` for >30 min means DNS validation hasn't propagated.
Confirm the validation CNAME is visible:

```bash
dig +short CNAME _acme-challenge.platforma.yourcompany.bio
```

Should return a `meta.gcp.googledomains.com.`-style hostname. If empty, the
Cloud DNS A record / CNAME hasn't propagated yet — give it 5-15 min.

### Desktop App: "no healthy upstream" or "service unavailable"

The Gateway's load-balancer health check is failing. Check:

```bash
gcloud compute backend-services list --global --project=YOUR_PROJECT \
  --format="table(name,protocol)"
```

Should include a backend with `protocol: H2C`. If only `HTTP` shows up, the
gRPC backend protocol isn't being declared — usually transient on first
provision; wait a few min. If persistent, check the
[forthcoming chart fix tracking issue](#) for `app.service.appProtocols.grpc`.

## Open chart-side fixes (tracking)

Two chart fixes are pending in the upstream `pl` repo — they'll flow into
this chart via the sync workflow on the next pl release. Until then, the GCP
installer ships its own workarounds:

- [pl#1789](https://github.com/milaboratory/pl/pull/1789) — chown-workspace
  initContainer (replaces deadlocked pre-install hook). Already mirrored
  into the bundled chart copy in this repo.
- [pl#1790](https://github.com/milaboratory/pl/pull/1790) — Service
  appProtocols. The installer currently provisions a parallel
  `platforma-grpc` Service in `dns_tls.tf` to carry the appProtocol; once
  this PR merges and a 3.4.0 chart release is cut, the workaround drops.
