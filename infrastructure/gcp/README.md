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
                            ┌────────────────────────────────────────────────┐
                            │        Your GCP project (created by you)       │
                            │                                                │
  Desktop App  ──HTTPS──▶  ┌─┴────────────┐                                  │
                            │ GKE Gateway   │  TLS at L7, gRPC to backend    │
                            │ + Cert Mgr    │                                │
                            │ + Cloud DNS   │                                │
                            └─┬────────────┘                                 │
                              │                                              │
                              │  internal HTTP/2                             │
                              ▼                                              │
                      ┌────────────────────────┐                             │
                      │  GKE Standard cluster  │                             │
                      │  (private nodes,       │                             │
                      │   public ctrl plane)   │                             │
                      │                        │                             │
                      │  ┌─system pool─────┐   │                             │
                      │  │ Platforma srv   │   │                             │
                      │  │ Kueue / AppWr   │   │ ──ServiceAccount──▶ GCS    │
                      │  └─────────────────┘   │     (Workload Identity)    │
                      │  ┌─UI pool──────┐      │                             │
                      │  │ scale 0-N    │      │ ──Filestore CSI──▶ Filestore (Zonal SSD)
                      │  └──────────────┘      │                             │
                      │  ┌─batch (ComputeClass)┐│                            │
                      │  │ platforma-batch      ││                            │
                      │  │ n2d→n2→std fallback   ││                            │
                      │  │ auto-created, 0-N     ││                            │
                      │  └──────────────────────┘│                            │
                      └────────────┬───────────┘                             │
                                   │ private IPs only                        │
                                   ▼                                         │
                            ┌──────────────┐                                 │
                            │  Cloud NAT   │ ── public egress for image     │
                            │  + Router    │    pulls / external LDAP /     │
                            │              │    cross-cloud demo data       │
                            └──────────────┘                                 │
                                   ┃                                         │
                                   ┃ Private Google Access (no NAT cost)    │
                                   ┃ for *.googleapis.com                   │
                            └──────┸──────────────────────────────────────────┘
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

`deployment_size` controls the batch capacity envelope (Kueue batch queue
quota), UI pool max size, Filestore default capacity, and the values the
installer requests via the Cloud Quotas API. **All sizes share the same
per-job cap of 62 vCPU / 484 GiB RAM** — the preset controls total concurrent
batch parallelism.

Batch runs on a single GKE **ComputeClass** (`platforma-batch`) that provisions
nodes on demand across multiple instance families and **falls back across
families on capacity stockout** — if the primary AMD family (`n2d`) is out of
capacity in the zone, GKE tries Intel (`n2`) and then standard shapes instead
of leaving jobs pending. Nodes carry the `role=batch` label and
`dedicated=batch:NoSchedule` taint, scale to zero when idle, and are created
without cluster-wide Node Auto-Provisioning (the ComputeClass's own
`nodePoolAutoCreation`). Total concurrent batch work is capped by the Kueue
ClusterQueue admission quota below.

Machine-type priority list (fallback order, all on-demand):

| Priority | Machine type | vCPU / Mem | Family | Role |
|---|---|---|---|---|
| 1 | `n2d-highmem-16`  | 16 / 128 GiB | N2D (AMD) | size tier |
| 2 | `n2d-highmem-32`  | 32 / 256 GiB | N2D (AMD) | size tier |
| 3 | `n2d-highmem-48`  | 48 / 384 GiB | N2D (AMD) | size tier |
| 4 | `n2d-highmem-64`  | 64 / 512 GiB | N2D (AMD) | primary (max 62/484 job) |
| 5 | `n2-highmem-64`   | 64 / 512 GiB | N2 (Intel) | stockout fallback |
| 6 | `n2d-standard-128`| 128 / 512 GiB | N2D (AMD) | last resort |
| 7 | `n2-standard-128` | 128 / 512 GiB | N2 (Intel) | last resort |

Batch capacity envelope + UI nodes per preset:

| Preset | Batch vCPU | Batch Mem (GiB) | UI nodes max |
|---|---:|---:|---:|
| `small`  |  320 |  1645 |  4 |
| `medium` |  640 |  3290 |  8 |
| `large`  | 1280 |  6580 | 16 |
| `xlarge` | 2560 | 13160 | 16 |

Other preset values:

| Preset | Filestore (GiB) | CPUs (global) | N2D CPUs (region) | N2 CPUs (region) | PD SSD GB (region) | Filestore Zonal GiB (region) | Instances (region) | In-use IPs (region) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `small`  | 1024 |  512 |  512 |  512 |  4096 | 1024 |  32 | 16 |
| `medium` | 2048 | 1024 | 1024 | 1024 |  8192 | 2048 |  48 | 16 |
| `large`  | 4096 | 2048 | 2048 | 2048 | 16384 | 4096 |  64 | 24 |
| `xlarge` | 8192 | 4096 | 4096 | 4096 | 32768 | 8192 | 128 | 32 |

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
| System pool (2× n2d-standard-8) | $0.80 |
| Filestore Zonal 1 TiB | $0.40 |
| Static IP + Cloud DNS records + Cert Manager | ~$0 |
| **Idle total** | **~$1.30/hour (~$940/month)** |

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
  - [`teardown.sh`](cloudshell/teardown.sh) — clean-teardown driver. Use instead of raw `gcloud infra-manager deployments delete` to avoid stuck PV finalizers on the chart's retained PVCs.
- [`domain-guide.md`](domain-guide.md) — Cloud DNS zone creation + delegation from external registrars (Route53, Cloudflare, GoDaddy, Namecheap).
- [`permissions.md`](permissions.md) — fine-grained IAM role set replacing `roles/owner` on the deployer SA.
- [`advanced-installation.md`](advanced-installation.md) — Tier-3 local-Terraform path with manual gcloud auth, custom backends, full customization.

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
install, tedious for repeated updates. Pin to a chart release tag (e.g.
`v3.3.10` — same scheme as `charts/platforma/Chart.yaml: version`, pushed
automatically by the backend release pipeline) for production; pull the new
tag when a release is announced.

#### Optional advanced env vars

These don't change the deployed cluster shape but tune ops behavior — set in
addition to (not instead of) the block above when you need them.

```bash
# Skip QuotaPreference creation entirely. Required on long-lived projects
# whose effective quotas already exceed the deployment_size preset by >10x —
# Cloud Quotas API rejects any preference that lowers an effective limit by
# more than 10% (FAILED_PRECONDITION / QUOTA_DECREASE_TOO_LARGE).
export ENABLE_QUOTA_AUTO_REQUEST=false

# Allow 'gcloud infra-manager deployments delete' to drop the primary GCS
# bucket even when it still contains workspace results. Default is to keep
# the bucket (data-loss protection — mirrors the AWS S3 retention pattern in
# the CloudFormation runbook). Set to true on dev/test deployments where
# bucket contents are disposable so teardown completes in one shot.
export GCS_FORCE_DESTROY=true
```

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

Tier-1 / Tier-2 — use the bundled `teardown.sh`:

```bash
bash infrastructure/gcp/cloudshell/teardown.sh
```

It accepts the same `PROJECT_ID` / `DEPLOYMENT_NAME` / `IM_LOCATION` env vars as
`install.sh`. The script deletes the chart's three PVCs first, then submits
`gcloud infra-manager deployments delete` — that ordering avoids the helm
provider's destroy hanging on stuck PV finalizers (see the next subsection for
the background).

Tier-3: `tofu destroy`.

The primary GCS bucket is **retained** for data safety (Terraform `force_destroy
= false`). To remove it after the deployment is destroyed:

```bash
gcloud storage rm -r gs://platforma-platforma-cluster-XXXXXXXX
```

The Cloud DNS zone you set up in [`domain-guide.md`](domain-guide.md) is **not
managed by this module** — leave it in place if you'll re-deploy.

### Why `teardown.sh` exists (and what happens without it)

The Platforma chart annotates its PVCs (`platforma-database`, `platforma-logs`,
`platforma-workspace`) with `helm.sh/resource-policy: keep` so `helm uninstall`
preserves the data on production teardowns — useful when re-installing into
the same cluster without losing workspace artifacts.

For a **full destroy**, that annotation is in the way:

1. `gcloud infra-manager deployments delete` runs `terraform destroy`.
2. Terraform's `helm_release.platforma` destroy uninstalls the chart, but the
   `keep`-annotated PVCs stay behind.
3. Terraform then tries to destroy the PVs (which it owns indirectly via the
   chart). The `kubernetes.io/pv-protection` finalizer prevents PV deletion
   while a PVC is still `Bound`, so PV deletion hangs.
4. After the 30 min `helm_release.timeout`, terraform aborts with
   `Error uninstalling release: context deadline exceeded`, leaving the GKE
   cluster, Filestore, network and other resources behind.
5. Operator has to delete the PVCs manually, then re-run the destroy.

`teardown.sh` deletes the three PVCs **before** calling the IM delete, so the
PVs release cleanly and the destroy run finishes in one shot (~10 min).

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
provision; wait a few min.
