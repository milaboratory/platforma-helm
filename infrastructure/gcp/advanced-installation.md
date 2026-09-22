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

### Authentication

Every deployment carries an `admin` htpasswd login, whichever other sources
you configure. No variable creates it and none removes it. Read its
auto-generated password from `terraform output password_retrieve_command`,
or from the Cloud Console URL in `terraform output post_deploy_steps`.

`sso_provider`, `ldap_server` and `enable_local_users` combine — set any
mix of them and every source you turn on is advertised together:

```hcl
sso_provider         = "google"
google_client_id     = "12345-abc.apps.googleusercontent.com"
google_client_secret = "GOCSPX-..."

ldap_server          = "ldaps://ldap.yourcompany.bio:636"
ldap_bind_dn         = "cn=%u,ou=users,dc=yourcompany,dc=bio"

enable_local_users   = true
htpasswd_content     = "alice:$2y$05$Xk1.../rest.of.the.bcrypt.hash"
```

Grant the admin role to logins from a source with that source's admin-user
variable — a semicolon-separated list of full-match regexps:

```hcl
sso_admin_users   = "alice@example.com;^ops-.*$"
ldap_admin_users  = "svc-admin"
local_admin_users = ""
```

`auth_method` is deprecated. It still configures one source on its own, but
does not combine with the variables above, and the apply fails if you set both.
Each of its five values moves to one of them: `ldap` to `ldap_server`,
`htpasswd` to `enable_local_users`, and `google` / `entra` / `oidc` to
`sso_provider`.

A `--admin-user=` entry left in `additional_extra_args` also fails the apply —
the backend grants the admin role per login source now, so a global
`--admin-user` flag reaches nobody. Move each pattern to the variable of the
source that authenticates it: `sso_admin_users`, `ldap_admin_users`, or
`local_admin_users`.

`enable_local_users = true` needs `htpasswd_content` set, and `htpasswd_content`
needs a source that advertises it — `enable_local_users = true` or a legacy
`auth_method = "htpasswd"`. Either mismatch fails the apply, naming the line to
add. A deployment upgrading from before this module wrote `auth.providers` —
one that never set `auth_method` and only ever supplied an htpasswd file — must
add `enable_local_users = true`, and its apply fails until it does.

An admin-user variable also needs its own source advertised: `sso_admin_users`
needs `sso_provider` set, `ldap_admin_users` needs `ldap_server` set, and
`local_admin_users` needs `enable_local_users = true`. Otherwise the apply
fails, naming the variable that turns the source on.

#### LDAP authentication

```hcl
ldap_server      = "ldaps://ldap.yourcompany.bio:636"
ldap_start_tls   = false

# Direct-bind mode (simpler when usernames map predictably to DNs):
ldap_bind_dn     = "cn=%u,ou=users,dc=yourcompany,dc=bio"

# OR search-bind mode:
# ldap_search_rules    = ["(uid=%u)|ou=users,dc=yourcompany,dc=bio"]
# ldap_search_user     = "cn=svc-platforma,ou=services,dc=yourcompany,dc=bio"
# ldap_search_password = "..."
```

#### Pre-bcrypted htpasswd (single-team production)

```hcl
enable_local_users = true
htpasswd_content   = "alice:$2y$05$Xk1.../rest.of.the.bcrypt.hash"
```

A tfvars file cannot call functions, so `htpasswd_content` holds the file's
text rather than `file("./htpasswd")`. To read it from the file itself, pass it
on the command line:

```sh
terraform apply -var="htpasswd_content=$(cat ./htpasswd)"
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

#### SSO (OIDC) authentication

PKCE auth-code flow. Most IdPs use a public/native client with no secret; Google
requires a client secret even for PKCE. Three presets via `sso_provider`:

```hcl
# Google Workspace — issuer, scopes and prompt are predefined.
sso_provider         = "google"
google_client_id     = "12345-abc.apps.googleusercontent.com"
google_client_secret = "GOCSPX-..."
```

```hcl
# Microsoft Entra ID — issuer derived from the tenant.
sso_provider    = "entra"
entra_tenant_id = "53dff85f-903c-48f0-908b-00aa35e40dad"
entra_client_id = "2f2c6eed-cddc-4375-96f6-92ccebe29648"
```

```hcl
# Any OIDC provider — full control. Optional fields default to backend values.
sso_provider       = "oidc"
oidc_issuer        = "https://idp.example.com/oidc"
oidc_client_id     = "ld69k866zvhnhz3xr1xwd"
oidc_scopes        = "openid profile email"   # optional
oidc_resource      = ""                        # optional
oidc_prompt        = ""                        # optional
oidc_user_id_claim = ""                        # optional
oidc_groups_claim  = ""                        # optional
```

The installer rejects a method whose required inputs are missing (and a
non-`https` OIDC issuer). Advanced backend flags not exposed as tfvars
(`subject-token-source`, `jwt-algorithm`, `redirect-port`) default to backend
values. Override them through `additional_extra_args`. The chart's flat
`auth.sso.*` block is not a route from here — the module writes
`auth.providers`, and the chart refuses the two schemes together.

> **Switching an existing instance's auth method (e.g. LDAP→SSO) is a manual
> operation** — see the [LDAP→SSO migration runbook](../ldap-to-sso-migration.md).
> It is not automated by this installer and carries identity-remap, lockout, and
> session-loss risks.

**Before you run this on an existing SSO deployment:** every user record must
carry a verified email, which means every user has completed at least one SSO
login under the current configuration. A record seeded without a login has no
verified email, so the first login under the new scheme mints a second
account and nothing merges the two.

Changing the set of auth sources re-derives the JWT signing key, so every
signed-in user signs in once more after this apply.

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
no per-shape pool definitions to override. The ComputeClass names the
machine types explicitly (`batch_machine_priorities` — size tiers smallest-first,
standard and highmem ratios interleaved at each vCPU count, `n2d-*` then
`n2-*` per tier) and creates node pools as
batch pods appear, scaling to zero when idle. The `deployment_size` preset sets
the **Kueue ClusterQueue** admission quota — the real cap on concurrent batch
work; the ComputeClass itself has no ceiling.

Override individually:

```hcl
deployment_size = "large"

ui_pool_max_nodes      = 8       # preset large = 16; UI is still a static pool
workspace_capacity_gb  = 8192    # preset large = 4096

# Kueue caps for very large jobs. The DEFAULT is preset-driven:
#   small/medium  62 CPU / 484Gi   (n2d-highmem-64)
#   large         94 CPU / 731Gi   (n2d-highmem-96)
#   xlarge       126 CPU / 824Gi   (n2-highmem-128)
# 484Gi = measured GKE allocatable on n2d-highmem-64 (486.94 GiB)
# minus ~1 GiB GKE DaemonSet overhead minus 1 GiB safety margin; the
# large/xlarge are likewise MEASURED (733.81 / 826.38 GiB allocatable on
# real GKE 1.35 nodes). Overriding requires a machine in
# batch_machine_priorities whose allocatable can host the request —
# n2-highmem-128 (826.38 GiB) is the largest shape in the default list. A request above a shape's
# allocatable passes Kueue admission and then sits Pending forever.
# Overriding DOWNWARD is always safe -- e.g. cap jobs on this `large`
# cluster at the small/medium ceiling:
kueue_max_job_cpu     = 62
kueue_max_job_memory  = "484Gi"
#
# Overriding UPWARD past the preset's shape is now REJECTED at deploy time:
# the chart compares kueue.maxJobResources against kueue.largestNode (which
# the installer derives from the preset) and fails the render rather than
# letting Kueue admit a job no node can host. On `large` that means 94 /
# 731Gi is the maximum; to go higher, move to deployment_size = "xlarge".

# Override the Kueue ClusterQueue admission quota (the cluster-wide batch
# envelope). Kueue won't admit more concurrent batch work than this,
# regardless of pending demand.
kueue_batch_queue_cpu    = 1500
kueue_batch_queue_memory = "8000Gi"
```

To change which machine types the ComputeClass provisions (e.g. add a family
once the team has verified it), edit `batch_machine_priorities` in **both**
`terraform-infra/presets.tf` and `terraform-platforma/presets.tf` (the
`batch_machine_priorities` block is kept byte-identical between them) and add
the matching `<FAMILY>-CPUS` quota request in `terraform-infra/quotas.tf`, the
`<family>_cpus_quota` preset key, and the `PRESET_<FAMILY>_CPUS` table in
`cloudshell/install.sh` (the recipe is spelled out in a comment there).

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

### GPU pools

GPU pools (L4 + RTX PRO 6000) are opt-in and gated on `enable_gpu`:

```hcl
enable_gpu = true

# Optional — override the per-shape pool maps ({machine-shape = [zones]}). The
# Cloud Shell installer auto-discovers these via `gcptest.sh` (one entry per
# shape the region actually offers); in the local Terraform path set them
# explicitly or run gcptest.sh yourself and copy the maps. A shape you omit
# gets no pool. Leave unset (null) to fall back to the full default ladder in
# the primary zone.
gpu_l4_pools = {
  "g2-standard-4"  = ["us-central1-a", "us-central1-b", "us-central1-c"]
  "g2-standard-8"  = ["us-central1-a", "us-central1-b"]
  "g2-standard-16" = ["us-central1-b"]
}
gpu_rtx_pro_6000_pools = {
  "g4-standard-6" = ["us-central1-b"]
}

# Optional — override the Kueue GPU ClusterQueue admission caps. By default
# these scale with `deployment_size` (see README's "GPU Kueue queue" table).
# kueue_gpu_queue_count   = 12     # max concurrent GPU jobs
# kueue_gpu_queue_cpu     = 448    # sized to fit gpu_count × largest single-GPU shape
# kueue_gpu_queue_memory  = "1792Gi"
```

**GPU quotas are not auto-submitted.** Request `NVIDIA L4 GPUs` and/or
`NVIDIA RTX PRO 6000 GPUs` in the regional Cloud Quotas Console before
running `tofu apply` with `enable_gpu = true` — the first GPU pool create
fails immediately if the regional quota is 0. See the
[GPU Support section in the runbook](README.md#gpu-support-opt-in) for the
SKU → quota mapping and per-preset values.

To enable GPU on an existing GPU-less deployment: add `enable_gpu = true`
(and any zone overrides) to `terraform.tfvars`, then `tofu plan && apply`.
The plan adds the GPU pools and Kueue GPU flavor without touching the
existing CPU pools or batch queue.

### Extra Platforma server args

Append arbitrary flags to the Platforma server command line. The module always
sets `--default-docker-registry` and `--google-artifact-registry`;
`additional_extra_args` is concatenated after them, so use it for flags the
module does not manage:

```hcl
additional_extra_args = ["--some-flag=value", "--another-flag"]
```

Each element must be one whole argument starting with `-` (validation rejects a
flag and its value split across two elements).

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
