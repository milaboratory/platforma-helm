# Migration: Monolithic GCP Module → Split infra/platforma Modules

Procedure to move an existing GCP Platforma deployment from the original single Terraform root module onto the refactored two-module layout, **without destroying or recreating a single cloud resource**.

## Overview

### What Is Changing

The first GCP deployment path (branch `chore/gcp-monolith-backport`) had one Terraform root module at `infrastructure/gcp/terraform/` and one Infrastructure Manager deployment. `main` splits that in two:

| | Monolith | `main` |
|---|---|---|
| Root modules | `terraform/` | `terraform-infra/` + `terraform-platforma/` |
| IM deployments | `<name>` | `<name>-infra` + `<name>-platforma` |
| Local backend prefix | `infrastructure/gcp` | `infrastructure/gcp/infra`, `.../platforma` |
| Coupling between them | n/a | `terraform-platforma/data.tf` discovers the cluster, service accounts, bucket and Filestore **by name** — no `terraform_remote_state` |

Nothing about the running deployment changes: the same GKE cluster, the same bucket, the same Filestore, the same Helm release. What changes is **which Terraform state file claims ownership of each resource**.

### Why This Is a State Split, Not an Import

The obvious reading of "move to the new modules" is *import every resource into the new configuration*. That would be the wrong tool here, for a concrete reason: **the refactor barely renamed anything**. Comparing the two trees address by address, almost every `resource` block in the monolith appears verbatim in one of the two new modules — same type, same name.

That means the job is a *partition* of one state file, not a re-derivation of it. Partitioning has two decisive advantages over importing:

* **It carries the un-importable resources.** `terraform_data.appwrapper_manifest_integrity` and `null_resource.wait_gateway_gfe_cleanup` have no cloud identity and cannot be imported at all. Under an import-based migration they would be recreated — and recreating `wait_gateway_gfe_cleanup` churns the Gateway/GFE.
* **It cannot get an ID wrong.** Importing ~50 GCP resources means hand-writing ~50 identifiers in GCP's various formats. A partition copies the identifiers that Terraform itself wrote.

Infrastructure Manager supports the partition directly, through `export-statefile` / `import-statefile`.

### The Flow

```
  monolith IM deployment "<name>"
             │
             │ export-statefile
             ▼
      monolith.tfstate ──────────► golden-monolith.tfstate  (read-only reset point)
             │
             │ split-state.jq  (pure partition, no address rewrites)
             │
     ┌───────┴────────┐              …and 3 addresses dropped from both:
     ▼                ▼                the master-secret trio, see below
 infra.tfstate   platforma.tfstate
     │                │
     │  seed: apply an EMPTY bundle so the deployment exists
     │  lock → import-statefile → unlock
     ▼                ▼
 "<name>-infra"  "<name>-platforma"
     │                │
     │  preview the REAL bundle  ── must show zero destroys ──► gate
     ▼                ▼
   apply (via cloudshell/install.sh)
```

`-infra` must be complete before `-platforma` is planned: `terraform-platforma/data.tf` resolves the cluster endpoint, the two runtime service accounts, the GCS bucket and the Filestore instance at **plan** time, and hard-fails if they are not there.

### The One Genuinely Dangerous Item: the Master Secret

The monolith **owns** the master secret:

```
random_id.master_secret
  └─► google_secret_manager_secret.master_secret
        └─► google_secret_manager_secret_version.master_secret
```

`main` has no such resource. The refactor converted it to bring-your-own: `cloudshell/install.sh:prestage_master_secret` creates the Secret Manager entry out of band, and `terraform-platforma/app.tf` reads it through `data.google_secret_manager_secret_version.master_secret`, addressed by `var.master_secret_secret_id` (which has **no default** — plan fails without it).

So the three resources above are removed from Terraform management (`migration.sh` drops them from both halves) while the Secret Manager object itself is left untouched and fed back in by name.

> **This is the step that turns a routine migration into a data-loss event if it is done wrong.** The master secret is the encryption key for the deployment's artefacts. If it is destroyed and recreated, every existing project becomes unreadable — and no backup of the *infrastructure* will bring it back. Never approve a plan that touches `google_secret_manager_secret.master_secret`, and never let the migration script's `DROP` list be "fixed" by moving those entries into a keep list.

Two details to check against the deployment you are actually migrating:

* `install.sh` expects the name `${DEPLOYMENT_NAME}-cluster-platforma-master-secret`. A monolith deployment may have used a different name. **Read the real name out of the exported state and pass that** — do not rename the secret.
* If the monolith deployment predates the BYO change, the secret's only version was created by Terraform. It stays valid; only the ownership changes.

### Static Batch Node Pools (Older Deployments Only)

Deployments created before the batch ComputeClass migration provisioned one **static batch node pool per machine shape** (`google_container_node_pool.batch`, a `for_each`). The split module has none: batch nodes are created on demand by the `platforma-batch` ComputeClass that `terraform-platforma/computeclass.tf` installs.

There is nothing in the new configuration for those pools to map onto, so they leave Terraform management with the split — `migration.sh` classifies them as `RETIRE`. That is not a problem in itself: the nodes keep running and keep serving jobs throughout. After the migration, once the ComputeClass is demonstrably scheduling new batch work, they are drained and deleted by hand (Phase 5b).

A deployment migrated from a recent monolith will not have these in state at all, and `classify` will simply report them as listed-but-absent. Check which case you are in before starting — it is the difference between a five-phase migration and a six-phase one.

### Already Handled For You

`terraform-platforma/helm.tf` carries a `moved` block:

```hcl
moved {
  from = kubectl_manifest.appwrapper["/api/v1/namespaces/appwrapper-system"]
  to   = kubectl_manifest.appwrapper_namespace
}
```

The AppWrapper namespace was extracted out of a `for_each` into a standalone resource. Without the `moved` block Terraform would plan a destroy of the namespace, which cascades to everything inside it. It is already in `main`, so it costs you nothing — but do not delete it until every environment has migrated.

---

## Audience and Scope

Written for an operator with `gcloud` and Owner-equivalent rights on the target project, running from Cloud Shell or a workstation. It assumes the monolith deployment is **ACTIVE** in Infrastructure Manager. If your monolith state instead lives in a plain GCS backend (someone ran `tofu apply` by hand), the split is simpler — `tofu state mv -state-out` between two state files — and the IM-specific phases (2, 3) do not apply.

Prerequisites: `gcloud` ≥ 450, `jq`, and a checkout of this repository at `main`.

---

## Operator Procedure

All commands run from `infrastructure/gcp/migration/`, with:

```sh
export PROJECT_ID=your-project
export DEPLOYMENT_NAME=platforma       # the EXISTING monolith deployment name
export IM_LOCATION=europe-west1        # default; override if you deployed elsewhere
```

Everything through Phase 3 is reversible and creates no cloud resources. Phase 4 is read-only. Phase 5 is the first step that changes anything.

### Phase 0 — Preflight and the golden snapshot

**Freeze changes first.** Pause any CI job or scheduled `apply` that targets this project, and do not run the monolith's `install.sh` again for the duration — applying the monolithic module on top of a half-migrated cluster is the one way to get two states fighting over the same resources.

```sh
./migration.sh preflight
./migration.sh export
```

`preflight` checks tooling, auth, that the monolith is ACTIVE, that the two targets do not already exist, and that the IM deployer service account is present.

`export` pulls the monolith state to `.work/<project>-<name>/monolith.tfstate` and takes a read-only copy as `golden-monolith.tfstate`. **That golden copy is your reset button** — every later phase can be redone by starting from it, without re-provisioning a GKE cluster. Keep it until the migration is validated and the old deployment is gone.

### Phase 1 — Classify and split

```sh
./migration.sh classify
./migration.sh split
```

`classify` asserts that **every** managed address in the exported state falls into exactly one of four lists in `migration.sh`:

| List | Count | Meaning |
|---|---|---|
| `KEEP_INFRA` | 31 | moves into `<name>-infra` |
| `KEEP_PLATFORMA` | 18 | moves into `<name>-platforma` |
| `DROP` | 3 | leaves Terraform management permanently; the cloud object stays (the master-secret trio) |
| `RETIRE` | 1 | leaves Terraform management, then is deleted by hand in Phase 5b (static batch pools; absent on recent monoliths) |

If someone has added a resource to the monolith module that this script does not know about, classify aborts and names it.

> When that happens, decide which module owns the new resource and add it to the right list. Do not silence the failure by adding it to `DROP` or `RETIRE` — those two lists have exact, documented memberships, and widening them is how a resource gets silently orphaned.

`split` runs `split-state.jq` twice to produce `infra.tfstate` and `platforma.tfstate`, then verifies the result independently: the two halves plus `DROP` must reconstitute the source address set exactly, with no overlap. The transformation also clears stale `outputs` and `check_results`, prunes dependency edges that point into the other half, and bumps `serial` so the import cannot be mistaken for stale.

### Phase 2 — Seed the target deployments

```sh
./migration.sh seed
```

`import-statefile` requires a deployment that already exists **and** is locked, but the only way to create a deployment is to apply a bundle — and applying the real bundle against an empty state would provision a second copy of everything.

`seed/main.tf` breaks that cycle: a root module with zero resources and no providers. IM creates each deployment in seconds with an empty state, which Phase 3 then overwrites.

### Phase 3 — Import the split state

```sh
./migration.sh import
```

Per deployment: `lock` → `import-statefile` → `unlock`, then an immediate `export-statefile` read-back whose address list is diffed against what was uploaded. The unlock runs from a `trap`, so a failed import still releases the lock — a deployment left locked cannot be applied and the lock id is awkward to recover.

At this point both target deployments believe they manage the real resources, and no cloud resource has been touched.

### Phase 4 — The zero-destroy gate

Produce the two tfvars files. `cloudshell/install.sh` in `main` builds these with `build_tfvars_json_infra` (line ~1578) and `build_tfvars_json_platforma` (line ~1609) from one user-supplied document; the simplest path is to run `install.sh` far enough to emit them, or to hand-write them from the monolith's inputs plus the new required keys.

**The new keys the monolith never had:**

| Key | Module | Notes |
|---|---|---|
| `master_secret_secret_id` | platforma | **Required, no default.** Must name the *existing* secret — read it from `golden-monolith.tfstate`, do not invent it. |
| `sso_*` | platforma | Only if adopting SSO; see `advanced-installation.md`. |

Save them as `.work/<project>-<name>/inputs-infra.auto.tfvars.json` and `inputs-platforma.auto.tfvars.json`, then:

```sh
./migration.sh preview
```

This stages each real module (stripping `backend.tf`, which IM rejects), creates an IM preview against the imported state, lists the resource changes, and **fails the run if any change has intent `DELETE` or `REPLACE`**.

**Expected non-destructive changes.** The refactor added resources the monolith never had; these show up as creates and are correct:

*infra* — `google_artifact_registry_repository.pl_containers` + its two IAM members, `google_container_node_pool.gpu_l4`, `google_container_node_pool.gpu_rtx_pro_6000`, `google_project_iam_member.server_batch_{agent_reporter,jobs_editor,service_agent}`, `google_service_account_iam_member.server_batch_run_as_self`.

*platforma* — `kubernetes_secret.sso_client_secret` (if SSO is configured), and `kubectl_manifest.appwrapper_namespace` should appear as a **move**, not a create-and-destroy, courtesy of the `moved` block.

#### Why a destroy can appear at all — config drift

This is the failure mode to understand before reading the preview, because it is the only one that can destroy a stateful resource despite everything above being done correctly.

Adopting a resource puts its **live attributes** into state. Terraform then diffs those attributes against the **new module's configuration**. Where they disagree you get an update — and for **immutable** GCP fields an update means destroy-and-recreate:

* node pool: `machine_type`, `disk_type`, `disk_size_gb`, image type
* cluster: `network`, `subnetwork`, location
* Filestore: `tier`, capacity

Recreating the `system` or `ui` node pool drains those nodes. Recreating the cluster or the Filestore instance is unrecoverable.

The good news is that the split module's `system` and `ui` pools are defined from the **same variables** as the monolith, with the same defaults — so if your tfvars carry the same values the monolith used, they plan as no-ops. Spurious replacements almost always trace to one of:

* a different `system_pool_machine_type` or `deployment_size` preset in the new tfvars than the monolith actually ran with;
* a `zone_suffix` mismatch, so the module addresses a different location than the resources live in;
* GKE release-channel auto-upgrades having moved the node version since the monolith last applied — a **version-only** diff is safe, a machine-type diff is not.

Reconcile by making the new module's inputs match reality. **Never reconcile by editing the state.** The authoritative values are in `golden-monolith.tfstate`:

```sh
jq -r '.resources[] | select(.type=="google_container_node_pool")
       | "\(.name)\t\(.instances[0].attributes.node_config[0].machine_type)"' \
   .work/*/golden-monolith.tfstate
```

#### Reading a non-zero preview

Do not approve your way past a destroy. Diagnose it:

| Symptom | Likely cause |
|---|---|
| `google_secret_manager_secret.master_secret` appears at all | The `DROP` list was bypassed. Stop; re-split from the golden snapshot. |
| The AppWrapper namespace is destroyed | The `moved` block was removed, or the bundle staged for preview is not from `main`. |
| A node pool is replaced | A machine-type/disk field differs between the monolith's inputs and the tfvars you wrote. Reconcile the tfvars — not the state. |
| The whole cluster is replaced | `cluster_name`, `zone`, or `project_id` in the tfvars does not match what the monolith created. |
| `kubectl_manifest.*` all replaced | Provider jump: the monolith pins `alekc/kubectl >= 2.1, < 2.4`, the split module uses `~> 2.4`. Confirm on the rehearsal before touching a real deployment. |

### Phase 5 — Apply

Only after both previews are clean. Apply the real bundles through the normal path — `cloudshell/install.sh` on `main`, which applies `<name>-infra` first and waits for it to settle before `<name>-platforma`. This script deliberately does not drive the applies; there is no reason to have a second, less-tested code path for the step that actually changes production.

### Phase 5b — Retire the static batch pools

**Skip this phase unless `classify` reported `RETIRE` addresses present in your state.**

The old static `batch-*` node pools are now managed by nothing. They keep running and keep serving whatever is already scheduled on them; new batch work goes to ComputeClass-provisioned nodes. Confirm that has actually started happening:

```sh
kubectl get nodes -L cloud.google.com/compute-class,role
# expect nodes carrying compute-class=platforma-batch,
# and no running job pods left on the batch-* nodes
```

Then:

```sh
./migration.sh retire
```

This reads the cluster name **and location** out of `golden-monolith.tfstate`, lists the surviving `batch-*` pools, and **prints** the delete commands without running them — deleting a node pool drains every node in it, and only you can judge whether the ComputeClass is genuinely carrying the load. Delete one pool at a time.

> The location matters: the monolith deploys a **zonal** cluster, so these commands use `--location=<zone>` (e.g. `europe-west1-b`), not a region. A `--region` here addresses a different or non-existent cluster.

Since the pools are in no Terraform state, this is a plain GCP cleanup with nothing to reconcile afterwards.

### Phase 6 — Retire the monolith deployment

Once the deployment is validated (see below), remove IM's record of the old monolith:

```sh
gcloud infra-manager deployments delete "${DEPLOYMENT_NAME}" \
  --location="${IM_LOCATION}" --project="${PROJECT_ID}" \
  --delete-policy=abandon --quiet
```

> `--delete-policy=abandon` is not optional. Without it, IM runs `terraform destroy` against a state that still lists your cluster, bucket, Filestore and secrets — and destroys the deployment you just migrated.

Do this **last**, and only after validation: until it is deleted, the monolith deployment is a working rollback target.

---

## Validation

Before Phase 6:

1. Both previews showed zero destructive changes, and both applies completed.
2. The Platforma UI answers on the **existing** ingress IP with the **existing** certificate — proving `google_compute_global_address.ingress` and the cert-manager chain were adopted, not recreated.
3. **A project that existed before the migration still opens.** This is the master-secret check and the only one that matters for data. A fresh deployment will pass every other test while having silently lost the key.
4. The admin password still works. The partition carries `random_password.admin` across, so it should be unchanged — if it has rotated, `random_password.admin` was dropped somewhere it should not have been.
5. `gcloud infra-manager deployments describe` shows both new deployments ACTIVE.
6. The resource inventory is unchanged: no new cluster, bucket, or Filestore instance was created alongside the old one.
7. Batch jobs schedule onto ComputeClass nodes:
   ```sh
   kubectl -n platforma get pods
   kubectl get nodes -L cloud.google.com/compute-class,role
   ```

## Rollback

The rollback target depends on how far you got:

* **Through Phase 3** — nothing has changed in the cloud. Delete the two seeded deployments with `--delete-policy=abandon` (`ALLOW_RESET=yes ./migration.sh reset` does exactly this) and carry on using the monolith deployment, which is untouched.
* **After Phase 5** — the resources have been mutated by a real apply. Re-import `golden-monolith.tfstate` into the monolith deployment (it still exists; you have not run Phase 6), delete the two new deployments with `--delete-policy=abandon`, and apply the monolith bundle to reconcile. This is why Phase 6 comes last.
* **After Phase 6** — there is no automated rollback. Do not run Phase 6 until validation passes.

## Re-Running After a Failure

Each phase is idempotent in a specific way:

* `export` refuses to overwrite an existing `monolith.tfstate` and never rewrites the golden snapshot.
* `classify` and `split` are pure functions of the exported state; re-run freely.
* `seed` skips a deployment that already exists.
* `import` can be repeated — it overwrites the target's state wholesale, and re-verifies by read-back.
* `preview` creates a preview named `<deployment>-mig-preview`; delete the previous one (`gcloud infra-manager previews delete`) if the name collides.
* `retire` only ever prints commands; run it as often as you like.

If a rehearsal goes sideways, `ALLOW_RESET=yes ./migration.sh reset` deletes both target deployments with `--delete-policy=abandon` and clears the derived files, leaving the golden snapshot and the monolith deployment intact.

---

## Rehearsing First

Do not run this against a deployment with data until it has been rehearsed end to end. The rehearsal is cheap because the expensive part — standing up the monolith — happens once:

1. In a scratch project, deploy the monolith from `chore/gcp-monolith-backport` via its `cloudshell/install.sh`. Use a short `DEPLOYMENT_NAME` (it prefixes cluster, secret and certmap names, which have length limits).
2. Create at least one project in the Platforma UI, so validation step 3 has something to check.
3. Run Phases 0–5.
4. `ALLOW_RESET=yes ./migration.sh reset`, then re-run Phases 2–5 to confirm the procedure is repeatable rather than a one-off that happened to work.

The `kubectl` provider jump (`< 2.4` → `~> 2.4`) is the item most worth proving on a rehearsal: it is the one version change between the two module sets that touches how existing state is read.

## Files

| Path | Purpose |
|---|---|
| `migration/migration.sh` | Phase driver — preflight, export, classify, split, seed, import, preview, retire, reset |
| `migration/split-state.jq` | The state partition, as an auditable jq program |
| `migration/seed/main.tf` | Empty root module used to bring the target deployments into existence |
