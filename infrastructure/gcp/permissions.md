# Permissions reference — replacing `roles/owner` on the deployer SA

By default `install.sh` grants the Infrastructure Manager deployer service
account `roles/owner` on the project. That's the simplest thing that works
end to end, but many organizations forbid `Owner` grants outside of break-glass
accounts. This doc gives the fine-grained alternative — a precise list of
predefined roles that covers exactly what the Terraform module provisions.

If you're running the installer in your own dev/test project, leave
`roles/owner` — it's fine. If you're going to a regulated GCP project, follow
the fine-grained list below.

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
| `roles/compute.networkAdmin` | Create VPC, subnet, static IPs, service-networking peering |
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

That's 12 predefined roles. Together they cover everything the Terraform
module creates — no more, no less.

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
  roles/cloudquotas.admin
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

And set `dns_zone_project` in the Terraform inputs to the DNS project ID.

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
