# Platforma on GCP (GKE) — Runbook

> **Status:** Work in progress. Tier-1 quickstart (Cloud Shell tutorial) and
> Tier-2 manual install are functional; this README is a stub being expanded
> in Phase 7 of the GCP rollout. See
> [`cloudshell/`](cloudshell/) for the working installer and
> [`terraform/`](terraform/) for the underlying module.

A single Infrastructure Manager deployment provisions the full Platforma stack
on GKE: VPC, cluster + auto-scaling node pools, Filestore (SSD), GCS bucket,
Workload Identity, Kueue/AppWrapper, Helm release, plus an HTTPS ingress (Cloud
DNS A record + Certificate Manager managed cert + GKE Gateway). Mirrors the
AWS CloudFormation runbook in shape.

## Three install paths

| Tier | Audience | How |
|---|---|---|
| **1. Cloud Shell** | Non-IT user, single click | [Open in Cloud Shell](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/milaboratory/platforma-helm&cloudshell_workspace=infrastructure/gcp/cloudshell&cloudshell_tutorial=tutorial.md) — tutorial in side panel, `install.sh` collects ~10 inputs and submits Infrastructure Manager. ~25 min. |
| **2. Local CLI** | DevOps / IT admin | Run `install.sh` from your own shell (skips the Cloud Shell wrapper). Same script, same result. Pre-fill any prompt with env vars. |
| **3. Local Terraform** | Power user | Clone repo, edit `terraform/terraform.tfvars`, run `tofu apply` against a GCS state backend. Bypasses Infrastructure Manager — full control. |

All three share the same Terraform module under [`terraform/`](terraform/).

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

Larger sizes also request larger GCP quotas (CPUs, N2D CPUs, PD SSD,
Instances, Filestore). The installer auto-submits these via the Cloud Quotas
API on first run; **small/medium** typically auto-approve in seconds, **xlarge**
often needs human review (24–72 h).

If your project already has user-managed quota preferences, the installer
detects them, skips re-requesting (the API rejects duplicate creates), and
warns when an existing value is below the chosen preset's requirement.

## Authentication

Two methods supported (mirrors the AWS CloudFormation runbook):

- **htpasswd** — file-based local auth.
  - **Auto-generated** (`auth_method=htpasswd`, `htpasswd_content=""`): the
    installer creates a random admin password and stores it in Secret Manager.
    **TESTING ONLY** — the password ends up in Terraform state.
  - **User-supplied content** (`htpasswd_content` = pre-bcrypted string from
    `htpasswd -nB <username>`): production-ready single-team setup.
- **LDAP** (`auth_method=ldap`) — corporate directory integration. Supports
  direct-bind (template) or search-bind (rules + service-account creds).

## Data libraries

External read-only buckets that hold input data (e.g. fastq files). Without
data libraries, the cluster has no real input data beyond the bundled demo
dataset.

| Type | Same project | Cross-project / cross-cloud |
|---|---|---|
| `gcs` | Workload Identity — grant `platforma-server@<project>.iam.gserviceaccount.com` `roles/storage.objectViewer` on the bucket before installing | (HMAC keys; pass via `access_key`/`secret_key`) |
| `s3`  | n/a | IAM access keys |

The MiLaboratories **demo data library** (`enable_demo_data_library=true`,
default) mounts the public S3 bucket cross-cloud — same dataset the AWS path
uses. Disable for production deployments where you don't want it visible to
users.

## Files

- [`terraform/`](terraform/) — Terraform module (root).
  - [`presets.tf`](terraform/presets.tf) — deployment-size lookup table (source of truth).
  - [`variables.tf`](terraform/variables.tf) — full parameter reference.
  - [`terraform.tfvars.example`](terraform/terraform.tfvars.example) — minimal local-dev template.
- [`cloudshell/`](cloudshell/) — Tier-1 quickstart.
  - [`tutorial.md`](cloudshell/tutorial.md) — Cloud Shell walkthrough.
  - [`install.sh`](cloudshell/install.sh) — driver script (also runs standalone outside Cloud Shell).

## Forthcoming docs (Phase 7)

- `advanced-installation.md` — Tier-3 local-Terraform path with manual gcloud auth, custom backends, and per-cloud-region tuning.
- `permissions.md` — fine-grained IAM role set for the Infrastructure Manager service account (replaces the current `roles/owner` grant).
- `domain-guide.md` — creating a Cloud DNS managed zone and delegating from external registrars (Route53, Cloudflare, GoDaddy, etc.).
