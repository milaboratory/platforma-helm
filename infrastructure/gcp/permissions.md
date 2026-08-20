# Permissions reference — GCP (GKE) install / update / teardown

There are **two distinct principals** involved in a deployment, and they need
different permissions:

| Principal | Who / what it is | Section |
|---|---|---|
| **The operator** | The **human Google user** (or CI principal) who runs `install.sh`, re-runs it for updates, and runs `teardown.sh` from Cloud Shell or a local terminal. | [below](#permissions-for-the-operator-the-google-user-running-the-scripts) |
| **The deployer SA** | `platforma-im-deployer@<project>` — the service account Infrastructure Manager runs Terraform under. Provisions every GCP resource. | [Fine-grained role set for the deployer SA](#fine-grained-role-set-for-the-deployer-sa) |

The split matters: **everything inside the Terraform module runs as the
deployer SA**, not as the operator. The operator only needs permission for what
the driver scripts (`install.sh` / `teardown.sh`) do directly via `gcloud` and
`kubectl` — bootstrapping the deployer SA, submitting the Infrastructure Manager
deployment, pre-staging the master secret, and (on teardown) deleting the
chart's PVCs. The list below is derived from every `gcloud`/`kubectl` call the
two scripts make under the operator's own credentials.

## Permissions for the operator (the Google user running the scripts)

Grant these on the **deployment project**. `install.sh` and re-runs (updates)
need the same set; `teardown.sh` additionally needs the two `container.*` roles
for the `get-credentials` + `kubectl` PVC cleanup it performs before deleting
the deployment.

| Role | Why the scripts need it | Script operation | install / update | teardown |
|---|---|---|:--:|:--:|
| `roles/billing.viewer` | Pre-flight check that billing is enabled on the project. | `gcloud beta billing projects describe` | ✅ | |
| `roles/serviceusage.serviceUsageAdmin` | Enable the bootstrap APIs (`config`, `cloudquotas`) and create the Infrastructure Manager service identity. | `gcloud services enable …`; `gcloud beta services identity create` | ✅ | |
| `roles/dns.reader` | List Cloud DNS managed zones to pick the domain, and read the zone's nameservers for the delegation pre-check. | `gcloud dns managed-zones list` / `describe` | ✅ | |
| `roles/cloudquotas.viewer` | Detect existing quota preferences and read current effective limits (skip-collision + >10%-decrease pre-checks). | `gcloud [beta] quotas preferences/info describe` | ✅ | |
| `roles/iam.serviceAccountAdmin` | Create the `platforma-im-deployer` service account on first run. | `gcloud iam service-accounts create` / `describe` | ✅ | |
| `roles/resourcemanager.projectIamAdmin` | Bind the deployer SA's role(s) on the project — including the default `roles/owner` grant. **See the Owner-grant note below.** | `gcloud projects add-iam-policy-binding` | ✅ | |
| `roles/iam.serviceAccountUser` **on the deployer SA** | `actAs` the deployer SA when submitting / deleting the IM deployment (`apply --service-account=…`). | `gcloud infra-manager deployments apply` / `delete` | ✅ | ✅ |
| `roles/config.admin` | Create, describe, update, and delete the Infrastructure Manager deployment. | `gcloud infra-manager deployments apply` / `describe` / `delete` | ✅ | ✅ |
| `roles/secretmanager.admin` | Pre-stage the Platforma master secret (create the secret + add the first version) — Terraform reads it as a data source, so it must exist before apply. | `gcloud secrets create` / `versions add` / `describe` / `versions list` | ✅ | |
| `roles/storage.admin` | **Install:** list the primary GCS bucket by label for the summary (`storage.buckets.list`). **Teardown:** `teardown.sh` also *empties* the bucket before the infra destroy (recursive object list + delete), which needs `storage.objects.list` + `storage.objects.delete`. A narrower custom role must include all three. | `gcloud storage buckets list`; `gcloud storage rm -r` | ✅ | ✅ |
| `roles/container.clusterViewer` | Fetch cluster credentials (`get-credentials`) and list clusters, so `kubectl` can reach the cluster during teardown. | `gcloud container clusters list` / `get-credentials` | | ✅ |
| `roles/container.developer` | `kubectl` scale the Platforma Deployment to zero and delete / patch (finalizer-strip) the retained PVCs before the IM delete. Supersedes `clusterViewer`; grant `roles/container.admin` if your org's Kubernetes RBAC needs the wider scope. | `kubectl scale` / `delete pvc` / `patch pvc` | | ✅ |

### Manual Helm recovery needs more than `container.developer`

The documented `teardown.sh` flow is fully covered by the operator set above: the
operator only scales the Deployment to zero and deletes the PVCs (both allowed by
`container.developer`), while the **deployer SA** removes the chart's RBAC
(`roles`/`rolebindings`) during `terraform destroy`. But if you ever need to
`helm uninstall` **by hand** — e.g. to clear a failed release before
re-installing — that deletes RBAC directly, and `container.developer` **cannot**
delete `roles`/`rolebindings` (`container.roles.delete` /
`container.roleBindings.delete`). Run that manual cleanup as project **Owner** or
with `roles/container.admin`.

### The `roles/owner`-grant note

By default `install.sh` grants the deployer SA **`roles/owner`**. The operator
role set above is enough to make that grant as-is — **the operator does not need
to be a project Owner**. The deployer is a *service account*, and GCP allows
`resourcemanager.projects.setIamPolicy` (part of `roles/resourcemanager.projectIamAdmin`,
already in the table) to grant `roles/owner` to a service account directly. The
stricter "grant Owner through the Console and accept an email invitation" rule
applies only to granting Owner to **user** accounts — which the installer never
does.

Two things can still change this:

- **Delegated role grants / org policy.** If your organization restricts which
  roles a `projectIamAdmin` may hand out (the IAM *delegated role grants*
  feature), the Owner grant can be blocked even for a service account. Then use
  the least-privilege deployer path below.
- **No-Owner projects (regulated).** To avoid granting Owner to the SA at all,
  give the deployer SA the [fine-grained role set](#fine-grained-role-set-for-the-deployer-sa)
  below *instead*. `install.sh` currently grants Owner unconditionally, so this
  path depends on the `SKIP_DEPLOYER_SA_OWNER_GRANT` follow-up noted under
  "Apply the fine-grained role set".

### Grant the operator role set

Least-privilege operator (skips Owner; pair with the fine-grained deployer SA
role set below). Run once as a project Owner or Org Admin:

```bash
PROJECT_ID=your-project
OPERATOR="user:you@yourcompany.com"        # or "serviceAccount:ci@..." for CI
DEPLOYER_SA="platforma-im-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

# Project-level roles the operator needs for install / update / teardown
for role in \
  roles/billing.viewer \
  roles/serviceusage.serviceUsageAdmin \
  roles/dns.reader \
  roles/cloudquotas.viewer \
  roles/iam.serviceAccountAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/config.admin \
  roles/secretmanager.admin \
  roles/storage.admin \
  roles/container.clusterViewer \
  roles/container.developer
do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${OPERATOR}" --role="${role}" \
    --condition=None --quiet >/dev/null
done

# actAs on the deployer SA (scoped to the SA, not the whole project).
# The deployer SA must exist first — install.sh creates it, or create it
# manually with the snippet in the deployer-SA section below.
gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER_SA}" \
  --member="${OPERATOR}" \
  --role=roles/iam.serviceAccountUser \
  --project="${PROJECT_ID}" --quiet
```

> **Verification status:** this list is derived by statically tracing every
> `gcloud`/`kubectl` call the driver scripts make under the operator's own
> identity (`install.sh`, `teardown.sh`). Confirm against a real project by
> running install → re-run (update) → teardown with an operator that has only
> these roles; a `PERMISSION_DENIED` names the missing permission — add the
> matching role and update this table.

## Two service accounts the deployer SA touches

The deployer SA (the one IM runs Terraform under) creates **two more** service
accounts during apply:

| Service account | Used by | Role |
|---|---|---|
| `platforma-im-deployer@<project>.iam.gserviceaccount.com` | Infrastructure Manager (the deployer SA itself) | Provisions all infrastructure — needs the roles below |
| `platforma-server@<project>.iam.gserviceaccount.com` | Platforma server pod runtime (via Workload Identity) | Read/write the primary GCS bucket; sign URLs |
| `platforma-jobs@<project>.iam.gserviceaccount.com` | Job pods runtime (via Workload Identity) | Read/write the primary GCS bucket |

The deployer SA creates the other two during apply and grants them their
specific runtime roles. So when you grant the deployer SA permissions, you're
granting it the ability to:

1. Provision GCP resources (compute, storage, IAM, DNS, etc.)
2. Create the runtime SAs and grant them their narrower runtime permissions

## Fine-grained role set for the deployer SA

| Role | Why needed |
|---|---|
| `roles/serviceusage.serviceUsageAdmin` | Enable GCP APIs (`compute`, `container`, `file`, etc.) |
| `roles/compute.networkAdmin` | Create VPC, subnet, static IPs, service-networking peering, Cloud Router + Cloud NAT (private-node egress) |
| `roles/container.admin` | Create the GKE cluster + node pools, full kubectl/Helm access via OIDC |
| `roles/file.editor` | Create Filestore instance |
| `roles/storage.admin` | Create primary GCS bucket + grant runtime SAs `storage.objectAdmin` on it |
| `roles/dns.admin` | Create A + CNAME records inside the Cloud DNS managed zone |
| `roles/certificatemanager.editor` | Create DNS authorization, managed cert, cert map + entry |
| `roles/secretmanager.admin` | Create the auto-generated admin password secret + version |
| `roles/iam.serviceAccountAdmin` | Create the runtime service accounts (`platforma-server`, `platforma-jobs`) |
| `roles/iam.serviceAccountTokenCreator` | Grant `roles/iam.serviceAccountTokenCreator` to the runtime SAs on themselves (needed for GCS signBlob during URL signing) |
| `roles/resourcemanager.projectIamAdmin` | Add IAM bindings at the project level (Workload Identity bindings, runtime-SA project roles) |
| `roles/cloudquotas.admin` | Submit `QuotaPreference` requests for the deployment-size preset |
| `roles/artifactregistry.admin` | Create the quay.io pull-through cache repository (`<prefix>-containers`) and grant the runtime SAs `artifactregistry.reader` on it |

## Apply the fine-grained role set

Replace the `roles/owner` grant in `install.sh` with the loop below. Run once
when bootstrapping the project:

```bash
PROJECT_ID=your-project
SA_EMAIL=platforma-im-deployer@${PROJECT_ID}.iam.gserviceaccount.com

# Create the SA (no-op if it already exists)
gcloud iam service-accounts create platforma-im-deployer \
  --display-name="Platforma Infrastructure Manager deployer" \
  --project="${PROJECT_ID}" --quiet 2>/dev/null || true

# Grant the fine-grained role set
for role in \
  roles/serviceusage.serviceUsageAdmin \
  roles/compute.networkAdmin \
  roles/container.admin \
  roles/file.editor \
  roles/storage.admin \
  roles/dns.admin \
  roles/certificatemanager.editor \
  roles/secretmanager.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountTokenCreator \
  roles/resourcemanager.projectIamAdmin \
  roles/cloudquotas.admin \
  roles/artifactregistry.admin
do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None --quiet >/dev/null
done
```

Then in the installer, set the env var so `install.sh` knows the deployer
SA already exists with the right roles:

```bash
export SKIP_DEPLOYER_SA_OWNER_GRANT=true
bash install.sh
```

> **TODO**: the env-var override above isn't implemented yet — `install.sh`
> always grants `roles/owner`. Tracked as a follow-up to this doc; until then,
> after running the loop above also delete the `roles/owner` binding the
> installer adds:
>
> ```bash
> gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
>   --member="serviceAccount:${SA_EMAIL}" --role="roles/owner" --condition=None
> ```

## Cross-project Cloud DNS zone

If your Cloud DNS managed zone lives in a **different project** from the
Platforma deployment (e.g. a central network-services project), the deployer
SA needs `roles/dns.admin` on **that other project**, not the deployment one:

```bash
DNS_PROJECT=your-network-project
gcloud projects add-iam-policy-binding "${DNS_PROJECT}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role=roles/dns.admin \
  --condition=None
```

Point the deployment at the DNS project:

- **Tier-1 / Tier-2 (`install.sh`):** export `DNS_ZONE_PROJECT=<dns-project>`. The
  installer forwards it to Terraform (`dns_zone_project`) and uses it for the
  DNS-delegation pre-check.
- **Tier-3 (local Terraform):** set `dns_zone_project` in your tfvars.

The **operator** (the Google user running the scripts) also needs
`roles/dns.reader` on the DNS project — `install.sh`'s delegation pre-check reads
the zone's nameservers there before deploying.

## Org-level constraints to know about

- **`iam.disableServiceAccountKeyCreation`** — has no effect; the installer
  doesn't create or use service-account JSON keys (it uses Workload Identity
  for the runtime SAs and the IM-supplied identity for the deployer).
- **`iam.allowedPolicyMemberDomains`** (Domain Restricted Sharing) — unaffects
  the deployer's grants, all bindings are within your own org. Affects only
  data libraries that point at S3 / cross-tenant GCS buckets where you'd need
  `allUsers` or external-domain bindings.
- **VPC Service Controls perimeter** — the deployer SA needs network access
  to all the GCP service endpoints (storage.googleapis.com, container.googleapis.com,
  etc). If your project is inside a VPC-SC perimeter, those services need to be
  on the perimeter's allow-list.

## Verifying the role set is sufficient

Run the installer end-to-end against a project where the deployer SA has only
the fine-grained roles (no `roles/owner`). If something fails with
`Permission denied`, the gcloud error includes the missing permission name —
add the matching role.

The 12-role list above has been validated against the current Terraform
module (deployment_size=small, ingress_enabled=true, htpasswd auto-gen,
demo data library enabled). New variables / new resources may need additional
roles — keep this doc in sync with `terraform/*.tf`.
