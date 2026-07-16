# Upgrading an existing GCP (monolithic) deployment to Platforma 4.2.2

This guide is for deployments that were installed with the **single/monolithic**
GCP Terraform module (`infrastructure/gcp/terraform/`) via Google Cloud
Infrastructure Manager (`cloudshell/install.sh`).

It brings your running instance up to **chart 4.2.2** and fixes a provider
issue that can break re-deploys. The upgrade is **in-place and
non-destructive**: no node pools are deleted, no data is lost.

> If you are moving to the newer split (`terraform-infra` + `terraform-platforma`)
> layout, use the separate migration guide instead. This document keeps you on
> the monolithic module.

---

## What this update changes

| Change | Why | Impact on you |
|---|---|---|
| Platforma chart **→ 4.2.2** | Latest fixes and features | Platforma pod restarts once (rolling) |
| A **master secret** is created and injected | Chart 4.x requires it (signs sessions & resources) | **All users must log in again once** — only if upgrading from 3.5.0. No data loss. |
| `kubectl` Terraform provider pinned to **< 2.4** | Provider 2.4 breaks this module's plan on re-deploy | Removes a failure you may have already hit |
| **OOM job retries off by default** | 4.2.x no longer retries out-of-memory jobs by default | A job that runs out of memory now fails immediately with its original error, instead of being re-run at doubled memory. This prevents oversized retries from piling up and stalling the batch queue. |

> Coming from an earlier 4.1.x monolithic build (the master secret and provider
> pin already applied)? This is a straight chart bump to 4.2.2 — the master
> secret is unchanged, so **no re-login is required**.

> **Backend image:** chart 4.2.2 must run against the **4.2.2 Platforma image**.
> The chart sets this for you — the image tag defaults to the chart's appVersion
> (4.2.2), so no action is needed **unless** you pinned `platforma_image_override`
> in your inputs. If you did, point it at a 4.2.2 image (or clear it to use the
> default). Verify after upgrade with the `kubectl get deploy` command in step 3.

**What is NOT affected:**
- Your projects, blocks, and all analysis data — the master secret does **not**
  encrypt the main database.
- Your batch and UI node pools — they are untouched.
- Your storage (Filestore workspace, GCS bucket) and networking.

The master secret is generated automatically and stored in Google Secret
Manager as `<CLUSTER_NAME>-platforma-master-secret`. You do **not** need to
provide it.

---

## Prerequisites

- Access to the same GCP project where Platforma is deployed.
- The same values you used for the original install (project, cluster name,
  region, domain, license, auth). Infrastructure Manager updates the existing
  deployment in place, so reusing the same names is what keeps it non-destructive.
- `git` and `gcloud` (Cloud Shell already has both).

---

## Upgrade steps

### 1. Get the updated code

```bash
git clone https://github.com/milaboratory/platforma-helm.git
cd platforma-helm
git checkout chore/gcp-monolith-4.2.2
```

(Or, in an existing clone: `git fetch origin && git checkout chore/gcp-monolith-4.2.2`.)

### 2. Re-run the installer with your original settings

Set the same environment variables you used for the first install (at minimum
`PROJECT_ID`, `CLUSTER_NAME`, `REGION`, and your auth/license variables), then:

```bash
./infrastructure/gcp/cloudshell/install.sh
```

Infrastructure Manager detects the existing deployment and applies an **update**
(a new revision) rather than creating a new one. During apply it will:

1. Re-resolve providers (now pinned to a working `kubectl` version).
2. Create the master-secret Secret (in the cluster and in Secret Manager).
3. Upgrade the Helm release to chart 4.2.2 (rolling restart of the Platforma pod).

Expect the Helm step to take several minutes while the new image is pulled and
the pod becomes ready.

### 3. Verify

```bash
# Platforma pod is running the new version
kubectl -n platforma get pods
kubectl -n platforma get deploy platforma -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# Master-secret Secret exists in the cluster
kubectl -n platforma get secret platforma-master-secret

# ...and is retrievable from Secret Manager
gcloud secrets versions access latest \
  --secret="${CLUSTER_NAME}-platforma-master-secret" \
  --project="${PROJECT_ID}" | head -c 8; echo " ...(truncated)"
```

Then open the Platforma URL and log in. **The first login after the upgrade will
require re-authentication** — this is expected (sessions were re-signed under the
new master secret).

---

## Rollback

If you need to revert, re-run the installer from your previous ref (e.g. the tag
or commit you were on before). Note that chart 3.5.0 does not use the master
secret, so rolling back simply stops using it; your data is unaffected either way.

The generated master secret remains in Secret Manager. To force a new one on a
future apply, delete it first:

```bash
gcloud secrets delete "${CLUSTER_NAME}-platforma-master-secret" --project="${PROJECT_ID}"
```

---

## Questions

Contact MiLaboratories support (support@milaboratories.com) with your project ID
and cluster name if the upgrade does not complete or the Platforma pod does not
become ready.
