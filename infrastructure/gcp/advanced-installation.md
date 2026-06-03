# Advanced installation — local Terraform without Infrastructure Manager

This is the Tier-3 path for power users: clone the repo, edit `terraform.tfvars`,
run `tofu apply` directly. Bypasses Infrastructure Manager and the Cloud Shell
tutorial — you own state and authentication.

For the recommended one-click setup, see [README.md](README.md) (Cloud Shell +
Infrastructure Manager).

## When to use this path

- You want full control over Terraform state (own GCS bucket, not IM-managed)
- You're iterating heavily during customization and don't want each apply to
  go through IM's upload + Cloud Build cycle (~3-5 min overhead per apply)
- You're integrating into your own CI (Atlantis, Spacelift, GitHub Actions)
- You want to fork and modify the module
- You need configurations not exposed by `install.sh` (e.g. custom node-pool
  machine types, multi-zone clusters, cross-project DNS)

If none of those apply, use the Cloud Shell quickstart — it's strictly easier.

## Prerequisites

- **gcloud SDK** (`brew install --cask google-cloud-sdk` on macOS)
- **OpenTofu 1.5+ or Terraform 1.5+** (`brew install opentofu`)
- **kubectl** (for post-install verification)
- **helm** (for post-install verification)
- **A GCP project** with billing enabled
- **A registered domain + Cloud DNS managed zone** — see
  [domain-guide.md](domain-guide.md)
- **A Platforma license key** from MiLaboratories
- **Owner role** on the project (or the
  [fine-grained role set](permissions.md) for production)

## Setup

### 1. Authenticate gcloud and bind ADC quota project

```bash
PROJECT_ID=your-gcp-project

gcloud auth login
gcloud auth application-default login
gcloud auth application-default set-quota-project "${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"
```

The ADC quota-project binding is needed for the Cloud Quotas API our module
uses (without it, `tofu apply` fails with "user project required" on the
quota-preference resources).

### 2. Create a GCS state backend bucket

Terraform stores state in this bucket. Create it once per project:

```bash
TFSTATE_BUCKET=your-project-tfstate

gcloud storage buckets create "gs://${TFSTATE_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location=europe-west1 \
  --uniform-bucket-level-access

gcloud storage buckets update "gs://${TFSTATE_BUCKET}" --versioning
```

Versioning matters — protects against accidental state corruption.

### 3. Clone the repo and switch to the GCP module

```bash
git clone https://github.com/milaboratory/platforma-helm.git
# Or pin to a chart release tag (e.g. v3.3.10 — same scheme as
# charts/platforma/Chart.yaml: version, pushed by the backend release pipeline):
# git clone -b v3.3.10 https://github.com/milaboratory/platforma-helm.git

cd platforma-helm/infrastructure/gcp/terraform
```

### 4. Configure the backend

The repo includes `backend.tf` with a placeholder bucket. Edit it OR override
at `tofu init` time:

```bash
tofu init \
  -backend-config="bucket=${TFSTATE_BUCKET}" \
  -backend-config="prefix=infrastructure/gcp"
```

### 5. Configure inputs

Copy the example tfvars and edit:

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Required values:

```hcl
project_id    = "your-gcp-project"
region        = "europe-west1"
zone_suffix   = "b"
cluster_name  = "platforma-cluster"

deployment_size = "small"   # small | medium | large | xlarge
contact_email   = "ops@yourcompany.bio"
license_key     = "E-XXXXXXXXX..."

ingress_enabled = true
domain_name     = "platforma.yourcompany.bio"
dns_zone_name   = "yourcompany-bio"   # Cloud DNS zone resource name
```

`terraform.tfvars` is gitignored, so secrets are not committed. See
`variables.tf` for the full set of knobs (auth, data libraries, image
override, deployment size overrides, etc.).

### 6. Plan and apply

```bash
tofu plan -out=tfplan
# Review carefully — first apply creates ~70 resources
tofu apply tfplan
```

Provisioning takes ~20 minutes. Watch progress with `tofu apply` output. The
last few minutes are the Helm release rollout.

### 7. Connect the Desktop App

`tofu apply` prints outputs at the end. Key ones:

```
platforma_url               = "https://platforma.yourcompany.bio"
default_username            = "platforma"
password_secret_console_url = "https://console.cloud.google.com/security/secret-manager/..."
```

The module reads the **master secret** from a Secret Manager entry you
stage beforehand and points the chart at it. See [Master secret](#master-secret)
below for the staging step and rotation flow — this must be done before
the first `tofu apply`.

Wait for the TLS cert to provision (5-15 min after apply — check
`gcloud certificate-manager certificates describe platforma-cluster-cert
--location=global --project=${PROJECT_ID}` for `state: ACTIVE`).

Get the admin password from Secret Manager (URL above). Open the Desktop App,
**Add Connection → Remote Server**, enter the URL, log in.

## Common customizations

### Custom data libraries (mixed GCS + S3)

```hcl
enable_demo_data_library = true   # MiLab demo data, default true

data_libraries = [
  # Same-project GCS — Workload Identity, no creds. The TF module
  # auto-grants platforma-server / platforma-jobs roles/storage.objectViewer
  # on the bucket; just list it.
  { name = "internal-bam", type = "gcs", bucket = "my-co-bam" },

  # Cross-project GCS — set project_id; grant the runtime SAs
  # roles/storage.objectViewer on the bucket from the OTHER project before
  # applying (the deployer SA can't reach across projects).
  { name = "shared-fastq", type = "gcs", bucket = "shared-co-fastq",
    project_id = "shared-data-project" },

  # Cross-cloud / external S3 — IAM access keys required.
  { name = "vendor-data", type = "s3", bucket = "vendor-bucket",
    region = "us-east-1",
    access_key = "AKIA...", secret_key = "..." },
]
```

### LDAP authentication

```hcl
auth_method      = "ldap"
ldap_server      = "ldaps://ldap.yourcompany.bio:636"
ldap_start_tls   = false

# Direct-bind mode (simpler when usernames map predictably to DNs):
ldap_bind_dn     = "cn=%u,ou=users,dc=yourcompany,dc=bio"

# OR search-bind mode:
# ldap_search_rules    = ["(uid=%u)|ou=users,dc=yourcompany,dc=bio"]
# ldap_search_user     = "cn=svc-platforma,ou=services,dc=yourcompany,dc=bio"
# ldap_search_password = "..."
```

### Pre-bcrypted htpasswd (single-team production)

```hcl
auth_method      = "htpasswd"
htpasswd_content = file("./htpasswd")
```

Build the `htpasswd` file with one bcrypt line per user. `-c` **creates** the
file (use it only for the first user — it overwrites), `-B` selects bcrypt
(required by the chart):

```bash
htpasswd -cB ./htpasswd alice    # first user — prompts for the password
htpasswd -B  ./htpasswd bob      # add more users — omit -c, or it wipes the file
```

To add or remove a user later, edit the file and re-apply (`tofu apply`) — the
change rolls the `platforma-htpasswd-provided` secret. Non-interactive form
(password on the command line, lands in shell history): `htpasswd -cbB
./htpasswd alice 'S3cret!'`.

### Master secret

The chart requires a root key — the **master secret** — for security layer
configuration of Platforma: it affects encryption of sensitive data
persisted in the platform DB, active user sessions trust and other things
related to data and connection security (see
`charts/platforma/values.yaml` lines 58-78).

> **Rotating the master secret invalidates all DB-encrypted secrets,
> existing user sessions and so on.** Treat it as a long-lived root
> key.

The module **does not** create the Secret Manager entry and **does not**
generate the value. You stage both before the first `tofu apply` and
point Terraform at the secret name via the required tfvar
`master_secret_secret_id`. At apply time the module reads the latest
version through the Google provider, materializes it as the Kubernetes
secret `platforma-master-secret` (key `master-secret`) in the Platforma
namespace, and never writes the value through `tfvars` or any state
artefact other than the value cached in TF state for the data source.

(The Cloud Shell `install.sh` performs the staging step below
automatically; advanced-path operators do it themselves.)

#### Stage the secret before first apply

```bash
SECRET_NAME="${CLUSTER_NAME}-platforma-master-secret"

# Generate a fresh 32-byte value; or pipe in your own payload instead of
# `openssl rand` to pin a known secret.
openssl rand -base64 32 | gcloud secrets create "${SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --replication-policy=automatic \
  --data-file=-

cat >> terraform.tfvars <<EOF
master_secret_secret_id = "${SECRET_NAME}"
EOF
```

`master_secret_secret_id` has no default — `tofu plan` fails without it.

#### Rotation

Add a new version out-of-band and re-apply:

```bash
openssl rand -base64 32 | gcloud secrets versions add "${SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --data-file=-

tofu apply
```

The data source always reads `latest`, so no state import is needed. As
called out above, rotation invalidates everything encrypted under the
prior key — do it deliberately.

#### Re-apply / state-loss stability

Secret Manager is the source of truth. Rebuilding Terraform state from
scratch no longer rotates the master secret — TF just re-reads the
existing latest version.

#### Destroy

`tofu destroy` no longer touches the Secret Manager entry (Terraform
doesn't own it). If you really want it gone, delete it explicitly:

```bash
gcloud secrets delete "${SECRET_NAME}" --project="${PROJECT_ID}"
```

Before doing that, back the value up if you might want to restore the
stack with DB-encrypted data intact:

```bash
gcloud secrets versions access latest \
  --secret="${SECRET_NAME}" \
  --project="${PROJECT_ID}" > /path/to/secure/backup
```

### Cross-project Cloud DNS zone

```hcl
domain_name      = "platforma.yourcompany.bio"
dns_zone_name    = "yourcompany-bio"
dns_zone_project = "your-network-services-project"   # zone lives here, not project_id
```

The deployer SA (or your local gcloud account) needs `roles/dns.admin` on the
DNS project.

### Custom batch capacity

Batch nodes are provisioned on demand by a custom GKE **ComputeClass**
(`platforma-batch`) — cluster-wide Node Auto-Provisioning is off and there are
no per-shape pool definitions to override. The ComputeClass names highmem
machine types explicitly (`batch_machine_priorities`) and creates node pools as
batch pods appear, scaling to zero when idle. The `deployment_size` preset sets
the **Kueue ClusterQueue** admission quota — the real cap on concurrent batch
work; the ComputeClass itself has no ceiling.

Override individually:

```hcl
deployment_size = "large"

ui_pool_max_nodes      = 8       # preset large = 16; UI is still a static pool
workspace_capacity_gb  = 8192    # preset large = 4096

# Kueue caps for very large jobs (defaults: 62 CPU / 484Gi).
# 484Gi = measured GKE allocatable on n2d-highmem-64 (486.94 GiB)
# minus ~1 GiB GKE DaemonSet overhead minus 1 GiB safety margin.
# Raising this requires a machine in batch_machine_priorities whose
# allocatable can host the request — n2d-highmem-64 / n2-highmem-64 are
# the largest highmem shapes in the default priority list.
kueue_max_job_cpu     = 62
kueue_max_job_memory  = "484Gi"

# Override the Kueue ClusterQueue admission quota (the cluster-wide batch
# envelope). Kueue won't admit more concurrent batch work than this,
# regardless of pending demand.
kueue_batch_queue_cpu    = 1500
kueue_batch_queue_memory = "8000Gi"
```

To change which machine types the ComputeClass provisions (e.g. add a family
once the team has verified it), edit `batch_machine_priorities` in **both**
`terraform-infra/presets.tf` and `terraform-platforma/presets.tf` (kept
byte-identical) and add the matching CPU quota request in `quotas.tf`.

> **Deprecated:** `batch_pool_max_nodes_overrides` is now a no-op (there are no
> per-shape pools). The variable is kept for tfvars backwards-compatibility but
> does nothing. Use `kueue_batch_queue_cpu` / `kueue_batch_queue_memory` to
> tune the cluster-wide envelope instead.

### Skip quota auto-request

If your project already has user-managed `QuotaPreference` records and the
auto-request collides:

```hcl
skip_quota_requests = ["cpus_global", "n2d_cpus_region", "n2_cpus_region", "pd_ssd_region"]
```

Or disable auto-request entirely and manage quotas yourself:

```hcl
enable_quota_auto_request = false
```

## Updates

Edit `terraform.tfvars`, run:

```bash
tofu plan -out=tfplan
tofu apply tfplan
```

Some changes are in-place (chart values, Kueue quotas, scaling limits). Some
require resource recreation (e.g. `region`, `cluster_name`, `zone_suffix`,
`filestore_tier`). The plan shows you what will happen.

## Destruction

```bash
tofu destroy
```

The primary GCS bucket is **retained** for data safety (TF resource has
`force_destroy = false`). To delete it after `tofu destroy`:

```bash
gcloud storage rm -r gs://platforma-${cluster_name}-XXXXXXXX
```

The Cloud DNS zone you set up (Tier-2 of [domain-guide.md](domain-guide.md))
is **not managed by this module** — leave it in place if you'll re-deploy.

## Troubleshooting

- **First-apply quota errors** — auto-request submits but new quotas may take
  seconds (small bumps) to days (xlarge with human review). Re-run the apply
  once quotas land.
- **`Permission denied` on a specific resource** — your gcloud account /
  deployer SA is missing a role. Match the missing permission against
  [permissions.md](permissions.md) and add the role.
- **Helm release failure during apply** — `kubectl logs -n platforma -l app.kubernetes.io/name=platforma`
  shows the Platforma server's startup output. Common causes: missing
  required value, license key invalid, GCP service account not yet propagated
  (just retry).
- **Cert validation stuck** — `gcloud certificate-manager certificates describe
  platforma-cluster-cert --location=global` shows the cert state. If
  `PROVISIONING` for >30 min, check that the DNS authorization CNAME is
  visible via `dig +short CNAME _acme-challenge.<domain>`.

## Comparison to Infrastructure Manager path

|  | Local Terraform (this doc) | Infrastructure Manager |
|---|---|---|
| State backend | Your own GCS bucket | IM-managed |
| Authentication | gcloud ADC | IM service account |
| Iteration speed | Faster (no upload step) | Slower (~3-5 min upload + Cloud Build) |
| Audit trail | Your own (Terraform Cloud / Atlantis logs / git) | IM Console (Revisions tab) |
| Rollback | `tofu apply` an older tfvars | IM Console "Rollback to revision N" |
| Setup steps | More (state bucket, auth, …) | Fewer (just gcloud + Cloud Shell button) |
| Customization beyond exposed vars | Trivial (fork, edit) | Re-package needed |

Both consume the same Terraform module under
`infrastructure/gcp/terraform/`. State management is the only real difference.
