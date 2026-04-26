# Advanced installation — local Terraform without Infrastructure Manager

This is the Tier-3 path for power users: clone the repo, edit `terraform.tfvars`,
run `tofu apply` directly. Bypasses Infrastructure Manager and the Cloud Shell
tutorial — you own state, authentication, and iteration speed.

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
# Or pin to a stable release:
# git clone -b gcp-im-v1.0.0 https://github.com/milaboratory/platforma-helm.git

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
  # Same-project GCS — Workload Identity, no creds. Grant
  # platforma-server@<project>.iam.gserviceaccount.com
  # roles/storage.objectViewer on the bucket BEFORE applying.
  { name = "internal-bam", type = "gcs", bucket = "my-co-bam" },

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
htpasswd_content = file("./htpasswd")   # generate locally with: htpasswd -nB <user>
```

### Cross-project Cloud DNS zone

```hcl
domain_name      = "platforma.yourcompany.bio"
dns_zone_name    = "yourcompany-bio"
dns_zone_project = "your-network-services-project"   # zone lives here, not project_id
```

The deployer SA (or your local gcloud account) needs `roles/dns.admin` on the
DNS project.

### Custom node-pool sizing

The `deployment_size` preset sets sensible defaults. Override individually:

```hcl
deployment_size = "large"

# Overrides (any of these can be omitted to use the preset)
batch_pool_machine_type = "n2d-highmem-128"   # default n2d-highmem-64
batch_pool_max_nodes    = 24                   # preset large = 16
ui_pool_max_nodes       = 8                    # preset large = 16
workspace_capacity_gb   = 8192                 # preset large = 4096

# Kueue caps for very large jobs (default 62 CPU / 500Gi)
kueue_max_job_cpu      = 124
kueue_max_job_memory   = "1000Gi"
```

### Skip quota auto-request

If your project already has user-managed `QuotaPreference` records and the
auto-request collides:

```hcl
skip_quota_requests = ["cpus_global", "n2d_cpus_region", "pd_ssd_region"]
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
