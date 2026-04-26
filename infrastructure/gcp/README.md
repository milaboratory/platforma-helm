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

`deployment_size` controls per-batch-pool max-node counts, Kueue batch queue
quotas, Filestore default capacity, and the values the installer requests via
the Cloud Quotas API. **All sizes share the same per-job cap of 62 vCPU /
500 GiB RAM** — the preset controls per-pool parallelism.

The batch tier is split into **5 pool shapes** (mirrors AWS's 5 batch node
groups). All pools share the same K8s label (`role=batch`) and taint
(`dedicated=batch:NoSchedule`); the GKE Cluster Autoscaler picks the
smallest-fitting pool per pending pod. Small jobs land on small nodes, big
jobs on big nodes — bin-packing efficiency without manual placement.

Per-pool max-node counts per preset:

| Preset | 16c-64g | 32c-128g | 64c-256g | 32c-256g | 64c-512g | Total batch | UI nodes max |
|---|---:|---:|---:|---:|---:|---:|---:|
| `small`  |  4 | 2 | 1 | 2 | 1 | 10 |  4 |
| `medium` |  8 | 4 | 2 | 4 | 2 | 20 |  8 |
| `large`  | 16 | 8 | 4 | 8 | 4 | 40 | 16 |
| `xlarge` | 32 |16 | 8 |16 | 8 | 80 | 16 |

Pool shape mapping:

| Shape    | GCP machine type   | vCPU / Mem      | AWS counterpart |
|---|---|---|---|
| 16c-64g  | `n2d-standard-16`  | 16 / 64 GiB     | m7i.4xlarge |
| 32c-128g | `n2d-standard-32`  | 32 / 128 GiB    | m7i.8xlarge |
| 64c-256g | `n2d-standard-64`  | 64 / 256 GiB    | m7i.16xlarge |
| 32c-256g | `n2d-highmem-32`   | 32 / 256 GiB    | r7i.8xlarge |
| 64c-512g | `n2d-highmem-64`   | 64 / 512 GiB    | r7i.16xlarge |

Other preset values:

| Preset | Filestore (GiB) | CPUs (global) | N2D CPUs (region) | PD SSD GB (region) | Filestore Zonal GiB (region) | Instances (region) |
|---|---:|---:|---:|---:|---:|---:|
| `small`  | 1024 |  512 |  512 |  2048 | 1024 |  32 |
| `medium` | 2048 | 1024 | 1024 |  4096 | 2048 |  48 |
| `large`  | 4096 | 2048 | 2048 |  8192 | 4096 |  64 |
| `xlarge` | 8192 | 4096 | 4096 | 16384 | 8192 | 128 |

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

Batch + UI pools scale from zero, so they don't burn when idle. Active-job
cost varies with the pool the autoscaler picks for each job:

| Pool | Approximate $/hour per running node |
|---|---|
| 16c-64g  | ~$0.90 |
| 32c-128g | ~$1.80 |
| 64c-256g | ~$3.60 |
| 32c-256g | ~$2.30 |
| 64c-512g | ~$4.60 |

(Spot pricing in europe-west1, list price; commit / SUD discounts apply
separately.) Smaller jobs landing on smaller pools is the whole point of
the multi-pool design — a 16-vCPU MiXCR job on a `16c-64g` node costs ~$0.90/h
versus ~$3.60/h on a `64c-256g` node.

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
| `gcs` | Workload Identity — Terraform auto-grants `platforma-server` and `platforma-jobs` `roles/storage.objectViewer` on the bucket. Just list it in `data_libraries`. | Set `project_id` on the entry to point at the bucket's project. Then grant `platforma-server@<deployment-project>.iam.gserviceaccount.com` `roles/storage.objectViewer` on the bucket from that other project (the deployer SA can't reach across projects). Or use HMAC + `access_key`/`secret_key`. |
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
- [`architecture-decisions.md`](architecture-decisions.md) — ADR log: non-obvious choices made during the build (multi-pool batch, Filestore tier, Workload Identity, custom HCL vs standard modules, etc.). Read this before making structural changes.

## Updates

There are three update paths depending on what you're changing and which tier
you installed with. **All three submit a new IM revision (or `tofu apply`) on
top of the existing state — no data loss.** The on-disk database (Filestore
PVC) survives across updates.

### What you typically update

- **New backend release** (monthly chart bump): pull a newer release tag and
  re-deploy. The chart's `appVersion` flows to the running pod, which rolls
  with ~15-30 sec of gRPC blip. Desktop App reconnects automatically.
- **Add / remove / edit data libraries**: bump the list, re-deploy.
- **Switch auth** (htpasswd ↔ LDAP): change vars, re-deploy.
- **Resize**: change `deployment_size`, re-deploy. The installer auto-submits
  the new quota requests; node pools resize on next scheduling.
- **Recreation-required changes** (`region`, `cluster_name`, `zone_suffix`,
  `filestore_tier`): the plan will show resource recreation. Treat these as
  destroy + re-install rather than updates.

### Path 1 — re-run `install.sh` with env-var pre-fill (Tier-1 / Tier-2)

Re-running `install.sh` detects the existing IM deployment and creates a new
revision against it. Today the script re-prompts every input from scratch
(future improvement: pre-populate from the previous IM revision). To skip the
prompts, set every collected variable as an environment variable before
running:

```bash
# Copy-paste the values you used last time:
export PROJECT_ID=your-gcp-project
export DEPLOYMENT_NAME=platforma
export IM_LOCATION=europe-west1
export REGION=europe-west1
export ZONE_SUFFIX=b
export DEPLOYMENT_SIZE=small
export CONTACT_EMAIL=ops@yourcompany.bio
export LICENSE_KEY='E-XXXXXXXXX...'
export INGRESS_ENABLED=true
export DOMAIN_NAME=platforma.yourcompany.bio
export DNS_ZONE_NAME=yourcompany-bio
export AUTH_METHOD=ldap                                        # or 'htpasswd'
export LDAP_SERVER='ldaps://ldap.yourcompany.bio:636'
export LDAP_START_TLS=false
export LDAP_BIND_DN=''                                         # search-bind mode
export LDAP_SEARCH_RULES='(uid=%u)|ou=users,dc=yourcompany,dc=bio'
export LDAP_SEARCH_USER='cn=svc-platforma,ou=services,dc=yourcompany,dc=bio'
export LDAP_SEARCH_PASSWORD='...'
export ENABLE_DEMO=true

# Full data-libraries YAML — INCLUDING existing libraries, otherwise they're
# dropped from the deployment. Add the new entry at the end.
export DATA_LIBRARIES_YAML='
- name: existing-lib
  type: gcs
  bucket: existing-bucket
- name: new-lib
  type: gcs
  bucket: new-bucket
'

# Pull latest before re-running to pick up new chart / TF module changes:
git pull
bash infrastructure/gcp/cloudshell/install.sh
```

Without env vars set the script will prompt for each one — fine for the first
install, tedious for repeated updates. Pick a stable release tag (e.g.
`gcp-im-v1.0.0`) for production; pull the new tag when a release is announced.

### Path 2 — edit inputs in the IM Console (no script)

If you only need to change one or two inputs and don't want to set up env
vars:

1. Open `https://console.cloud.google.com/infra-manager/deployments?project=YOUR_PROJECT`.
2. Click the `platforma` deployment.
3. **Edit** → modify the inputs JSON directly (you'll see the full input set
   from the previous revision; just append to the `data_libraries` array,
   bump `deployment_size`, etc.).
4. **Submit** — IM creates a new revision against the same Terraform module.

Same end result as Path 1, GUI-driven.

### Path 3 — Tier-3 local Terraform (recommended for ongoing ops)

Once you're past the initial install, switching to Tier-3 makes updates a
one-liner:

```bash
cd platforma-helm/infrastructure/gcp/terraform
$EDITOR terraform.tfvars        # change one line
tofu plan -out=tfplan
tofu apply tfplan
```

State is in your own GCS bucket, inputs are git-trackable, no re-prompting.
See [`advanced-installation.md`](advanced-installation.md) for the migration
from IM-managed state to your own backend.

### Rollbacks

- **Tier-1 / Tier-2**: IM Console → **Revisions** tab → "Rollback to revision N".
- **Tier-3**: revert the tfvars change in git, `tofu apply`.

Both keep cluster + data intact and just re-roll the Helm release / TF resources
to the previous shape.

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
