# Migration: Monolithic GCP Module → Split infra/platforma Modules

Procedure to move an existing GCP Platforma deployment from the original single Terraform root module onto the refactored two-module layout, **without destroying or recreating a single stateful cloud resource**.

## Overview

### What Is Changing

The first GCP deployment path (branch `chore/gcp-monolith-backport`) had one Terraform root module at `infrastructure/gcp/terraform/` and one Infrastructure Manager (IM) deployment. `main` splits that in two:

| | Monolith | `main` |
|---|---|---|
| Root modules | `terraform/` | `terraform-infra/` + `terraform-platforma/` |
| IM deployments | `<name>` | `<name>-infra` + `<name>-platforma` |
| Coupling between them | n/a | `terraform-platforma/data.tf` discovers the cluster, service accounts, bucket and Filestore **by name** — no `terraform_remote_state` |

The running deployment does not change: the same GKE cluster, the same bucket, the same Filestore, the same Helm release. What changes is **which Terraform state file owns each resource**.

### How Adoption Works — and Why Not `import-statefile`

The obvious approach is to split the monolith's state file in two and hand each half to a new IM deployment through `export-statefile` / `import-statefile`. **Do not do this. It destroys the deployment.**

Infrastructure Manager cannot be handed a finished state file:

* `import-statefile` writes to a **draft** state, not the live state. A plain `export-statefile` read-back still shows the old (empty) state, so the import *looks* like it failed even though it succeeded.
* The **only** way to promote a draft to live is `unlock`. And `unlock` is not a passive lock release — it runs a full `terraform apply` of the deployment's current **configuration**. If that configuration is an empty seed module (the only thing you can apply to create the deployment before importing), the apply plans to destroy every resource the imported state lists, and **does it**.

This is not hypothetical — it wiped a test instance during development. `apply` while a deployment is locked is rejected, so there is no way to put the real configuration in front of the draft. The seed → import → unlock path has no safe form.

**So the migration adopts, it does not import-statefile.** Each target deployment is created directly from its real bundle (`terraform-infra` / `terraform-platforma`) plus a generated `imports.tf` of config-driven `import {}` blocks (Terraform 1.5+, which IM runs). On the first apply, Terraform **reads** each existing resource into state instead of creating it. The deployment is born managing the live resources, with no create and no destroy.

An adopted resource is indistinguishable from one Terraform created itself: later updates, and `deployments delete`, behave identically. Adoption changes only the birth event.

### The Flow

```
  monolith IM deployment "<name>"
             │
   export    │  export-statefile → golden-monolith.tfstate  (read-only; source of import IDs)
             ▼
   classify  │  every managed address must land in exactly one partition list
             ▼
   generate  │  per half: real bundle  +  inputs (projected via install.sh)  +  imports.tf
             │            (import IDs read from the golden state; moved{} targets remapped)
             ▼
   preview   │  IM preview of each half — READ ONLY — the zero-destroy gate
             ▼
   apply     │  deployments apply each half → import blocks adopt the live resources
             ▼
   cutover   │  abandon the monolith deployment (metadata only; no resources destroyed)
             ▼
   retire    │  drain + delete leftover static batch node pools, if any
```

`-infra` is adopted before `-platforma`: `terraform-platforma/data.tf` resolves the cluster endpoint, the two runtime service accounts, the GCS bucket and the Filestore instance at **plan** time, and hard-fails if they are not there.

Everything through `preview` is non-destructive — `export` reads, `generate` is local, and `preview` is a read-only plan. `apply` adopts (no create or destroy of existing resources). `cutover` abandons the monolith (metadata only). `retire` is the only step that deletes real, now-redundant resources.

### The One Genuinely Dangerous Item: the Master Secret

The monolith **owns** the master secret:

```
random_id.master_secret
  └─► google_secret_manager_secret.master_secret
        └─► google_secret_manager_secret_version.master_secret
```

`main` has no such resource. The refactor converted it to bring-your-own: `terraform-platforma/app.tf` reads it through `data.google_secret_manager_secret_version.master_secret`, addressed by `var.master_secret_secret_id`.

So the three resources above are removed from Terraform management — `migration.sh` lists them in `DROP` and generates **no** import block for them — while the Secret Manager object itself is left untouched and fed back in by name. `migration.sh` sets `master_secret_secret_id` to `${DEPLOYMENT_NAME}-cluster-platforma-master-secret` automatically.

> **This is the step that turns a routine migration into a data-loss event if it is done wrong.** The master secret is the encryption key for the deployment's artefacts. If it is destroyed and recreated, every existing project becomes unreadable, and no backup of the *infrastructure* will bring it back. Never approve a plan that touches `google_secret_manager_secret.master_secret`, and never let the `DROP` list be "fixed" by generating an import block for those entries.

If the monolith used a different secret name, override `master_secret_secret_id` — do not rename the secret.

### Resources With No Importer

`terraform_data.appwrapper_manifest_integrity` and `null_resource.wait_gateway_gfe_cleanup` have no cloud identity and **cannot be imported** — Terraform reports `Resource Import Not Implemented`. `migration.sh` lists their types in `SKIP_IMPORT` and generates no import block for them. They therefore appear in the preview as **CREATE**, which is expected and harmless: they hold no cloud object, so "creating" them only recomputes a trigger or re-runs a local wait. Nothing in the cluster is destroyed.

### Static Batch Node Pools (Older Deployments Only)

Deployments created before the batch ComputeClass migration provisioned one **static batch node pool per machine shape** (`google_container_node_pool.batch`, a `for_each`). The split module has none: batch nodes are created on demand by the `platforma-batch` ComputeClass that `terraform-platforma/computeclass.tf` installs.

There is nothing in the new configuration for those pools to map onto, so they leave Terraform management with the split — `migration.sh` classifies them as `RETIRE`. The nodes keep running and keep serving jobs throughout. After the migration, once the ComputeClass is demonstrably scheduling new batch work, they are drained and deleted by hand (`retire`).

A deployment migrated from a recent monolith will not have these in state at all, and `classify` reports them as listed-but-absent. Check which case you are in before starting.

### Moved Blocks Handled Automatically

`terraform-platforma/helm.tf` carries a `moved` block:

```hcl
moved {
  from = kubectl_manifest.appwrapper["/api/v1/namespaces/appwrapper-system"]
  to   = kubectl_manifest.appwrapper_namespace
}
```

The AppWrapper namespace was extracted out of a `for_each` into a standalone resource. The monolith state still holds the old address, so `gen-imports.jq` would emit an import block for it — and Terraform rejects importing to a move source. `migration.sh` reads every `moved` block in the bundle and **remaps** the import target from the old address to the new one. You do not need to touch this.

---

## Audience and Scope

Written for an operator with `gcloud` and Owner-equivalent rights on the target project, running from Cloud Shell or a workstation. It assumes the monolith deployment is **ACTIVE** in Infrastructure Manager. If your monolith state instead lives in a plain GCS backend (someone ran `tofu apply` by hand), the split is simpler — `tofu state mv -state-out` between two state files — and the IM-specific steps do not apply.

Prerequisites on the machine you run from: `gcloud` ≥ 450, `jq`, `gsutil`, `unzip`, `python3`, and a checkout of this repository at `main`. `migration.sh` sources `cloudshell/install.sh` to reuse its per-half input projection, so both must come from the same checkout.

---

## Operator Procedure

All commands run from `infrastructure/gcp/migration/`, with:

```sh
export PROJECT_ID=your-project
export DEPLOYMENT_NAME=platforma       # the EXISTING monolith deployment name
export IM_LOCATION=europe-west1        # default; override if you deployed elsewhere
```

Everything through `preview` is reversible and changes nothing in the cloud. `apply` is the first step that changes anything.

### Phase 0 — Preflight and the Golden Snapshot

**Freeze changes first.** Pause any CI job or scheduled `apply` that targets this project, and do not run the monolith's `install.sh` again for the duration — applying the monolithic module on top of a half-migrated cluster is the one way to get two states fighting over the same resources.

```sh
./migration.sh preflight
./migration.sh export
```

`preflight` checks tooling, auth, that the monolith is ACTIVE, that the two targets do not already exist, and that the IM deployer service account is present.

`export` pulls the monolith state to `.work/<project>-<name>/monolith.tfstate` and takes a read-only copy as `golden-monolith.tfstate`. Adoption reads every import identifier out of this file. **Re-export if the deployment has changed since your last export** — stale IDs (for example a different bucket suffix) make the import blocks miss the live resources.

### Phase 1 — Classify

```sh
./migration.sh classify
```

`classify` asserts that **every** managed address in the exported state falls into exactly one of four lists in `migration.sh`:

| List | Count | Meaning |
|---|---|---|
| `KEEP_INFRA` | 31 | adopted into `<name>-infra` |
| `KEEP_PLATFORMA` | 18 | adopted into `<name>-platforma` (2 of these types are state-only — recreated, not imported) |
| `DROP` | 3 | leaves Terraform management permanently; the cloud object stays (the master-secret trio) |
| `RETIRE` | 1 | leaves Terraform management, then is deleted by hand by `retire` (static batch pools; absent on recent monoliths) |

If someone has added a resource to the monolith module that this script does not know about, classify aborts and names it.

> When that happens, decide which module owns the new resource and add it to the right list. Do not silence the failure by adding it to `DROP` or `RETIRE` — those two lists have exact, documented memberships, and widening them is how a resource gets silently orphaned.

`classify` also reports addresses that are listed but **absent** from the state. That is expected for `count`/`for_each`-gated resources that are switched off in your deployment (for example a data-library IAM member or an unused auth secret), and for the `RETIRE` pool on an already-migrated monolith.

### Phase 2 — Generate the Adoption Bundles

```sh
./migration.sh generate
```

For each half, `generate` stages a directory under `.work/<project>-<name>/bundle-<half>/` containing:

* the **real module** (`terraform-infra` / `terraform-platforma`), minus `backend.tf` (IM manages state itself);
* `inputs.auto.tfvars.json` — the module's inputs, projected from the monolith's own recorded inputs by `install.sh`'s `build_tfvars_json_{infra,platforma}` (sourced, not re-implemented), plus the values only the split needs: `master_secret_secret_id`, and `system_pool_node_count` pinned to the live pool size (see [Config drift](#config-drift--forced-replace));
* `zzz-adoption-imports.tf` — the generated `import {}` blocks, one per live resource instance, with `moved{}` targets remapped.

Review the import file before previewing:

```sh
less .work/*/bundle-infra/zzz-adoption-imports.tf
less .work/*/bundle-platforma/zzz-adoption-imports.tf
```

### Phase 3 — Preview: the Zero-Destroy Gate

```sh
./migration.sh preview
```

For each half, `preview` creates a read-only IM preview of the staged bundle — the target deployment does not need to exist yet — lists the resource changes, and classifies them by their Terraform actions:

* **Any change carrying a `delete` action** (`DELETE` or `RECREATE`) is destructive. Unless the address is on the `ACCEPT_REPLACE` list, this **fails the run**.
* **A `CREATE` on an address that has an import block** means the import id did not match a live resource — an apply would make a duplicate. This also **fails the run**.
* A `CREATE` of a resource with **no** import block is a genuinely new resource the split adds (see below), or a state-only recreate. It is allowed, and listed for you to confirm.

`ACCEPT_REPLACE` is a short, reviewed allowlist of replacements the operator consents to. It currently holds `random_password.admin` and `google_secret_manager_secret_version.admin_password` — the split adds `override_special` to the admin password, which forces the random provider to regenerate it. **The admin password rotates on adoption.** The new value is published to the admin-password Secret Manager secret, so it stays retrievable; only a cached copy of the old one goes stale. Any *other* destructive change still stops the run.

**Expected non-destructive changes.** The refactor added resources the monolith never had; these show up as creates and are correct — for example, on the infra half, `google_artifact_registry_repository.pl_containers`, its two IAM members, and the `artifactregistry.googleapis.com` service. Confirm each create is a resource the split is meant to add.

#### Config Drift → Forced Replace

This is the failure mode to understand, because it is the only one that can destroy a stateful resource despite everything above being done correctly.

Adopting a resource puts its **live attributes** into state. Terraform then diffs those attributes against the **new module's configuration**. Where they disagree you get an update — and for **immutable** GCP fields an update means destroy-and-recreate:

* node pool: `initial_node_count`, `machine_type`, `disk_type`, `disk_size_gb`, image type
* cluster: `network`, `subnetwork`, location
* Filestore: `tier`, capacity

Recreating the `system` or `ui` node pool drains those nodes. Recreating the cluster or the Filestore instance is unrecoverable.

One drift is handled for you. The `system` pool is fixed (not autoscaled) and its `initial_node_count` is immutable; the monolith module defaulted it to **2**, terraform-infra defaults to **1**. `migration.sh` reads the live count from the golden state and pins `system_pool_node_count` to it, so the pool adopts in place. If you later want a different size, that is a deliberate, scheduled pool replacement — not a migration side effect.

Any other spurious replacement traces to the projected inputs disagreeing with reality — a `system_pool_machine_type` / `deployment_size` preset, a `zone_suffix` mismatch, or a GKE release-channel auto-upgrade that moved the node version (a version-only diff is safe; a machine-type diff is not). Reconcile by making the module's inputs match reality. **Never reconcile by editing the state.** The authoritative values are in `golden-monolith.tfstate`:

```sh
jq -r '.resources[] | select(.type=="google_container_node_pool")
       | "\(.name)\t\(.instances[0].attributes.node_config[0].machine_type)"' \
   .work/*/golden-monolith.tfstate
```

#### Reading a Non-Zero Preview

Do not approve your way past a destroy. Diagnose it:

| Symptom | Likely cause |
|---|---|
| `google_secret_manager_secret.master_secret` has an import block or a plan | It was moved out of `DROP`. Stop; restore the `DROP` list. |
| A `CREATE` on an import-blocked address | The import id is wrong for that resource type — a duplicate risk. Fix the id rule in `gen-imports.jq`. |
| A node pool is replaced | An immutable field (count, machine type, disk) differs between the live pool and the projected inputs. Reconcile the inputs — not the state. |
| The whole cluster is replaced | `cluster_name`, `zone_suffix`, or `project_id` in the inputs does not match what the monolith created. |
| The AppWrapper namespace is destroyed | The `moved` remap did not apply, or the bundle is not from `main`. |

### Phase 4 — Apply: Adopt

Only after both previews are clean.

```sh
./migration.sh apply
```

This runs `deployments apply` for each half against its staged bundle. The import blocks read the existing resources into state; nothing existing is created or destroyed. `-infra` is applied and settles before `-platforma`.

At this point both new deployments manage the live resources — **and so does the monolith**. That is safe as long as nothing applies the monolith. Do not run the monolith's `install.sh` between here and cutover.

### Phase 5 — Cutover: Abandon the Monolith

Once you have validated the deployment (see below):

```sh
./migration.sh cutover
```

This checks that both split halves are ACTIVE, then deletes the monolith deployment with `--delete-policy=abandon` — IM forgets it, but every cloud resource stays (the split deployments now own them).

> `--delete-policy=abandon` is not optional. Without it, IM runs `terraform destroy` against a state that still lists your cluster, bucket, Filestore and secrets. `cutover` always passes it; never delete the monolith by hand without it.

Do this **last**, and only after validation: until it is abandoned, the monolith deployment is a working rollback target.

### Phase 5b — Retire the Static Batch Pools

**Skip this unless `classify` reported `RETIRE` addresses present in your state.**

The old static `batch-*` node pools are now managed by nothing. They keep serving whatever is already scheduled on them; new batch work goes to ComputeClass-provisioned nodes. Confirm that has actually started:

```sh
kubectl get nodes -L cloud.google.com/compute-class,role
# expect nodes carrying compute-class=platforma-batch,
# and no running job pods left on the batch-* nodes
```

Then:

```sh
./migration.sh retire
```

This reads the cluster name **and location** out of `golden-monolith.tfstate`, lists the surviving `batch-*` pools, and **prints** the delete commands without running them — deleting a node pool drains every node in it, and only you can judge whether the ComputeClass is carrying the load. Delete one pool at a time.

> The location matters: the monolith deploys a **zonal** cluster, so these commands use `--location=<zone>` (e.g. `europe-west1-b`), not a region.

---

## Validation

Before `cutover`:

1. Both previews showed no destructive changes (except the accepted admin-password rotation), and both applies completed with the deployments ACTIVE.
2. The Platforma UI answers on the **existing** ingress IP with the **existing** certificate — proving `google_compute_global_address.ingress` and the cert-manager chain were adopted, not recreated.
3. **A project that existed before the migration still opens.** This is the master-secret check and the only one that matters for data. A fresh deployment passes every other test while having silently lost the key.
4. The admin password works. It **rotated** during adoption (see `ACCEPT_REPLACE`), so read the current value from the admin-password Secret Manager secret, not from a cached copy.
5. The resource inventory is unchanged: no new cluster, bucket, or Filestore instance was created alongside the old one.
6. Batch jobs schedule onto ComputeClass nodes:
   ```sh
   kubectl -n platforma get pods
   kubectl get nodes -L cloud.google.com/compute-class,role
   ```

## Rollback

The rollback target depends on how far you got:

* **Through `preview`** — nothing has changed in the cloud. Delete anything staged and carry on using the monolith, which is untouched.
* **After `apply`, before `cutover`** — the split deployments have adopted the resources, but the monolith still owns them too and remains authoritative. Delete the two new deployments with `--delete-policy=abandon` (`ALLOW_RESET=yes ./migration.sh reset`), then carry on with the monolith. The only lasting change is the admin-password rotation.
* **After `cutover`** — the monolith is gone. There is no automated rollback. Do not run `cutover` until validation passes.

## Re-Running After a Failure

Each step is idempotent in a specific way:

* `export` refuses to overwrite an existing `monolith.tfstate` and never rewrites the golden snapshot. Delete both by hand to force a fresh export after the deployment changes.
* `classify` and `generate` are pure functions of the golden state and the bundles; re-run freely.
* `preview` deletes and recreates its preview (`<deployment>-adopt-preview`) each run.
* `apply` refuses if a target deployment already exists — adoption must create it fresh. Reset first.
* `retire` only ever prints commands; run it as often as you like.

If a rehearsal goes sideways, `ALLOW_RESET=yes ./migration.sh reset` deletes both target deployments with `--delete-policy=abandon`, removes the staged bundles and previews, and leaves the golden snapshot and the monolith deployment intact.

---

## Rehearsing First

Do not run this against a deployment with data until it has been rehearsed end to end. The rehearsal is cheap because the expensive part — standing up the monolith — happens once:

1. In a scratch project, deploy the monolith via its `cloudshell/install.sh`. Use a short `DEPLOYMENT_NAME` (it prefixes cluster, secret and certmap names, which have length limits).
2. Create at least one project in the Platforma UI, so validation step 3 has something to check.
3. Run `preflight` → `export` → `classify` → `generate` → `preview` → `apply` → `cutover`.
4. `ALLOW_RESET=yes ./migration.sh reset`, then re-run from `apply` to confirm the procedure is repeatable.

The adoption import-id rules per resource type (helm release, kubectl manifest, IAM member, random password) are the item most worth proving on a rehearsal — the `preview` gate catches a wrong id safely, but you want to see it pass before touching a real deployment.

## Files

| Path | Purpose |
|---|---|
| `migration/migration.sh` | Flow driver — preflight, export, classify, generate, preview, apply, cutover, retire, reset |
| `migration/gen-imports.jq` | Emits the `import {}` blocks from the golden state, with per-type import-id rules |
