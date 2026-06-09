# Migration: Single-Server Platforma → Kubernetes

End-to-end procedure to move an existing single-server Platforma instance (running the standalone binary or Docker image) onto a Kubernetes cluster managed by this Helm chart.

## Overview

### What Is Being Moved

This migration moves a single-server Platforma — the standalone binary or Docker image running on one machine — onto a Kubernetes cluster on AWS managed by this Helm chart. Two kinds of state move with it:

1. **The database** — Platforma's internal record of every project, result, and setting, stored in an embedded RocksDB. It is exported to one compressed file, copied into the cluster, and restored.

2. **Primary storage** — the large data files analyses read and write (sequencing data, intermediate results, outputs), held in an S3 bucket. They are copied bucket-to-bucket into the cluster's new bucket. (If the source kept primary storage on local disk instead of S3, there is nothing to copy and the cluster starts with empty storage.)

### The Recommended Flow

Copying primary storage is the long pole — hours, sometimes days, for a multi-TB bucket. To avoid blocking users for that whole time, copy it **while the source keeps running**, and take downtime only for a short, consistent cutover at the end:

1. **Sync primary storage live** — start the bucket-to-bucket copy in AWS while Platforma keeps serving users.
2. **Start the downtime** once the live copy has caught up: stop all writes (pause Desktop App users and automated submitters).
3. **Back up the old instance** — a safety snapshot taken before the next, destructive step.
4. **Cancel running block computations** — pausing users does not stop work already in flight; cancelling clears it. This modifies the source database, which is why the safety backup in step 3 comes first.
5. **Take the migration database backup** — now consistent, with nothing mid-flight; this is the dump you restore into the new cluster.
6. **Sync the storage delta** — copy the handful of objects written between the live sync and the freeze.
7. **Install Platforma on the cluster (Helm)** — on first start it runs its internal database schema migration against the restored database.
8. **Drop the caches** — the source ran analysis software directly on its own disk; on Kubernetes that software runs in Docker, so results cached against the old setup are cleared and recomputed through the cluster's Docker executor.
9. **Start Platforma again** and validate.

For a small install you can skip the live copy: freeze first, then copy everything during the downtime. It is simpler, but downtime then lasts as long as the entire copy. Both paths are detailed below.

The source's data is modified only by the block cancellation in step 4; the safety backup in step 3 captures its pre-cancel state. Otherwise the source is left running untouched until you have validated the new cluster — if anything fails, discard the cluster's database and restore from the migration backup (see **Rollback** at the end).

---

## Operator Procedure

What follows is the detailed, executable procedure. The phases run around the Helm install: Phase 0 (source side) and Phase 1 (cluster prep) come before it, Phase 2 is the install itself, and Phase 3 finishes the switch afterward.

### Re-Running Steps After a Failure

If a step fails partway through you can re-run it, but the steps guard against accidental re-runs in different ways:

* **Database steps that write to the cluster disk** — Step 1.4 (download), Step 1.5 (restore), Step 1.6 (cleanup), and the Phase 3 cache invalidation — each check for a marker file, `/data/database/.migration-complete`, before doing anything. Phase 3 writes that marker only after cache invalidation finishes successfully. So once the migration has completed end to end, re-running any of these steps does nothing: the step finds the marker and exits immediately. (That is what "gating on the marker" means — the marker file acts as a gate that stops the step from running a second time.)

* **The s5cmd storage sync** (Step 1.3) can be re-run freely. It compares each object's ETag and copies only what is missing or changed, so a repeat run skips everything already copied and costs almost nothing.

* **The database dump** (Step 0.3) just overwrites `backup.gz` on the source host — re-running simply produces a fresh dump.

* **S3 Batch Replication** (Step 0.6.5) is the one step that is *not* safe to blindly re-run as written: its `ClientRequestToken` includes `$(date +%s)`, so every `aws s3control create-job` call starts a brand-new job. Rather than re-running it, check the existing job's status (Step 0.6.6) and create a new job only if the original genuinely failed.

## Audience and Scope

This guide is written for an operator running the migration by hand with the AWS CLI and kubectl. If you manage your infrastructure as code (Terraform, eksctl, etc.), translate the `aws ...` calls into the equivalent resources. The procedure assumes:

* You have provisioned the target cluster's infrastructure following the resources listed in [advanced-installation.md](cloudformation/advanced-installation.md) — that doc enumerates every IAM policy, IRSA role, S3 bucket, EFS filesystem, ACM certificate, and StorageClass that the Helm chart depends on. Translate each aws ... call into the equivalent Terraform resource.

* You have kubectl access to the cluster and admin permissions in the target namespace (platforma by default).

* You have AWS CLI access to both the **source** primary-storage S3 bucket (read) and the **destination** bucket (write). Cross-account migrations need an extra IAM user — see Cross-Account Sync below.

## Prerequisites

| Requirement | Notes |
| :---- | :---- |
| Source Platforma version | Same major.minor as the target chart's image. Cross-version restore is not supported. |
| Source database dump | Created with curl -s http://localhost:9091/db/state_raw | gzip > backup.gz, then uploaded to S3. The endpoint is part of the debug API — it requires --debug-enabled (or PL_DEBUG_ENABLED=true) on the source server, and binds to 127.0.0.1:9091 by default. See Phase 0. |
| Target cluster ready | Cluster Autoscaler, Kueue + AppWrapper, EFS CSI, EBS CSI, S3 IRSA all working. See [advanced-installation.md](cloudformation/advanced-installation.md) Steps 1–8. |
| Target S3 bucket created | Empty. The migration will sync data into it. |
| MI_LICENSE available | The migration uses the Platforma image to run --restore-db and --invalidate-caches, both of which need a valid license. |
| kubectl and AWS CLI | Configured for the target cluster and account. |
| Source instance frozen | Stop writes during the migration. The DB dump is a point-in-time snapshot. New work submitted after the dump is taken will be lost. |

## Migration Variables

Set these once before running any step. Each pre-helm command references them.

```bash
# Target cluster
export NAMESPACE="platforma"
export REGION="eu-central-1"
export CLUSTER_NAME="my-platforma-cluster"             # EKS cluster name — used for IAM role/policy names
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export S3_BUCKET="platforma-<your-cluster>-<suffix>"   # destination bucket (already created)
```

```bash
# Platforma image tag used by the migration pods (must match the source server's major.minor)
export PLATFORMA_VERSION="3.0.1"
# Helm chart version installed in Phase 2 — usually tracks PLATFORMA_VERSION but can differ
export CHART_VERSION="${PLATFORMA_VERSION}"
```

```bash
# License — required by the Platforma-image pods (restore + invalidate)
export MI_LICENSE="..."                                # paste the license token, or load from a file
```

```bash
# Source dump (required)
export MIGRATION_DATABASE_S3_URI="s3://my-backups/platforma-backup.gz"
```

```bash
# Source primary storage (optional — omit to skip storage sync)
export MIGRATION_SOURCE_BUCKET="old-platforma-bucket"
export MIGRATION_SOURCE_PREFIX=""              # leave empty for bucket root
export MIGRATION_SOURCE_REGION="eu-west-1"     # defaults to $REGION if empty
```

```bash
# Cross-account credentials (optional)
export MIGRATION_DB_ACCESS_KEY=""              # AKIA... — needed if dump is in another account
export MIGRATION_DB_SECRET_KEY=""
export MIGRATION_STORAGE_ACCESS_KEY=""         # AKIA... — needed if source bucket is in another account
export MIGRATION_STORAGE_SECRET_KEY=""
```

## Architecture of the Migration Job

All migration work runs as one-shot pods inside the target namespace. They use:

* The official Platforma image (quay.io/milaboratories/platforma:${PLATFORMA_VERSION}) for DB restore and cache invalidation.

* The amazon/aws-cli:2.27.22 image for S3 download/sync.

* Pod securityContext: fsGroup: 1010, runAsUser: 1010, runAsGroup: 1010 (matches the chart's non-root pl user — UID/GID **must** be 1010 or restored RocksDB files will be unreadable by the server pod).

* The platforma-database PVC (RWO, 50Gi, gp3) mounted at /data/database.

* The platforma-license Secret for the Platforma-image pods.

The YAML below defines those pods. Apply each manifest by hand as shown in the steps, or wire it into your own IaC (a Terraform `null_resource`, a `helm_release` provisioner, etc.).

---

## Migration Strategy: Online (Recommended) vs. Full-Freeze

The two strategies share every step below; they differ only in **when you freeze the source**, and therefore in how long users are offline.

**Online (recommended).** Copy the bulk of primary storage **while the source keeps running**, so users are not blocked during the long copy. Freeze only at the end, for a short **cutover** window in which you copy the small remaining delta and take the database backup. Downtime shrinks from "time to copy the whole bucket" to "time to copy what changed during the copy + dump the database" — typically minutes. This is the sequence summarized in **The Recommended Flow** above.

**Full-freeze (simpler, for small installs).** Freeze the source first (Step 0.1), then copy everything — database and all primary-storage objects — during the downtime. There is no live-copy machinery to set up, but downtime lasts as long as the entire copy: fine when storage is small, hours or days for a multi-TB bucket.

### Why Online Copy Is Safe

Online copy is safe because of how Platforma's primary storage behaves while the server runs:

* **Objects never change once written.** Every stored object is named by a hash of its own contents, so a file is written once and never modified in place. Copying it while the server runs can never catch it half-updated.

* **The server does not delete storage objects on a background schedule.** Objects are removed only when their record is explicitly deleted from the database. The worst case during an online copy is a harmless leftover: an object copied to the destination that the source later deletes. The destination simply keeps a few objects the final database no longer references — this wastes a little space but breaks nothing. (`aws s3 sync` and s5cmd only add objects; they never delete from the destination.)

* **The database does not hard-code the bucket.** It refers to storage objects by relative path plus a storage ID, not by absolute bucket URL, so switching to the new bucket is a config change, not a data rewrite.

The one rule that makes it correct: **take the database dump and the final storage delta sync inside the same freeze window.** Both then capture the same instant, which guarantees the destination bucket contains every object the dumped database references. Nothing written after the freeze can be referenced by the dump, and nothing the dump references can be missing from storage.

### How to Run the Online Variant

Follow the same numbered steps, re-sequenced like this:

1. **Before freezing — start the live bulk copy.** Choose the storage path that fits your bucket size:
   * **Multi-TB bucket → S3 Batch Replication.** First apply the live replication configuration (**Step 0.6.3**) so that *new* writes stream to the destination continuously, **then** start the backfill job (**Step 0.6.5**) to copy everything that already exists. Both run on the AWS side while users keep working.
   * **Smaller bucket → s5cmd.** Run **Step 1.3** now, while the source is live, and simply re-run it at cutover. Each run copies only what changed since the last (it compares ETags), so the cutover run is cheap.
2. **Freeze the source (Step 0.1).** From here, users are offline. Keep this window short.
3. **Final storage delta.** Let the replication job drain its last objects (or run the final s5cmd sync). Verify the destination object count matches the source.
4. **Back up, cancel running blocks, then take the migration dump (Step 0.3)** — safety backup of the old instance, cancel in-flight blocks, then the consistent dump.
5. **Continue** with upload, restore, Helm install, and cache invalidation exactly as written.

> **Versioning note.** S3 Batch Replication requires versioning on both buckets, and the **live** replication configuration means versioning must stay enabled for the entire online window — only suspend it after cutover (**Step 0.6.7**). Suspending afterward is safe: Platforma never uses object versions at runtime. The s5cmd path needs no versioning at all.

If the source kept primary storage on a **local filesystem** (not S3), there is nothing to pre-copy and the online variant offers no benefit — downtime is just the database dump and restore in either case.

---

## Phase 0: Source-Side Preparation

Steps 0.1–0.5 run on the **source** single-server host (the machine running the standalone binary or Docker image). Step 0.6 runs from a workstation with AWS CLI access — it is entirely AWS-side and has no dependency on the target Kubernetes cluster, so kicking it off here lets AWS copy data in the background while you complete the rest of Phase 0 and all of Phase 1.

Phase 0 produces:

1. A gzipped database dump uploaded to S3 (referenced by MIGRATION_DATABASE_S3_URI).

2. A frozen primary-storage S3 bucket whose name you record as MIGRATION_SOURCE_BUCKET.

3. For multi-TB buckets: a running S3 Batch Replication job that will populate the destination bucket before Phase 2.

### Step 0.1: Freeze the Source Instance

Stop all writes — pause Desktop App users and any automated submitters. Note that this stops only *new* work: blocks already running keep computing and writing results until they finalize, so they are cancelled explicitly in Step 0.3.2. The database dump and the storage bucket must represent the same point in time; objects written after the dump is taken will be invisible to the restored DB and orphaned in storage.

### Step 0.2: Enable the Debug API on the Source

The /db/state_raw endpoint is gated behind the debug API. If it is not already enabled, restart the source server with --debug-enabled (or set PL_DEBUG_ENABLED=true). The endpoint binds to 127.0.0.1:9091 by default — run the dump command **on the source host itself**, or temporarily change --debug-ip to bind to a routable interface.

Verify:

```bash
curl -sf http://localhost:9091/db/stats >/dev/null && echo "debug API reachable"
```

### Step 0.3: Back Up, Cancel Running Blocks, then Dump

Two database backups are taken here, with the block cancellation between them: the first protects the **old instance** (the cancel is destructive); the second is the consistent **backup for the new instance** that you restore into the cluster.

Both backups go through the debug-API endpoint (`/db/state_raw`, enabled in Step 0.2), which **requires the instance to be running**. The endpoint streams a tab-separated key/value dump of RocksDB; piping into gzip writes a single compressed file. Dump time scales with DB size — a 10 GB live DB typically compresses to 1–3 GB.

#### Step 0.3.1: Safety Backup of the Old Instance (before cancelling)

Take this snapshot **before** cancelling blocks. Cancelling is destructive — it discards in-flight computations and modifies the source database — so this backup is your rollback point for the old instance.

```bash
curl -s http://localhost:9091/db/state_raw | gzip > backup-pre-cancel.gz
```

#### Step 0.3.2: Cancel Running Block Computations

Pausing users (Step 0.1) stops new submissions, but blocks already in flight keep writing until they finalize. `--cancel-running-blocks` is a one-time action that cancels every running block across all projects and then exits without starting the service — so stop the normal source service first (RocksDB allows a single writer), then run it with the same data-dir and storage flags the source normally uses:

```bash
/app/platforma --cancel-running-blocks \
  --db-dir=<source-db-dir> \
  --license="<source-license>"
```

It deletes the non-final block output fields, so the restored database will not carry blocks stuck in a perpetual "running" state on the new cluster, where their computations no longer exist.

#### Step 0.3.3: Migration Dump — Backup for the New Instance (after cancelling)

This is the **consistent dump you upload and restore** — nothing is mid-flight. The dump needs the instance running, but `--cancel-running-blocks` exited the service, so **start the source service again first, with the debug API enabled** (the same `--debug-enabled` / `PL_DEBUG_ENABLED=true` as in Step 0.2 — otherwise `/db/state_raw` will not bind and the dump fails with connection-refused). Keep users and submitters paused: the cancelled blocks will not resume and no new work can arrive. Then dump through the same endpoint as in Step 0.3.1:

```bash
curl -s http://localhost:9091/db/state_raw | gzip > backup.gz
```

Continue to Step 0.4 to upload `backup.gz`.

### Step 0.4: Upload the Dump to S3

Use whatever S3 bucket the new cluster can read from. For same-account migrations, any bucket the migration IRSA role can s3:GetObject from works — that role is defined later in Step 1.2.1, so make sure the bucket you choose here will be covered by the policy you attach there.

```bash
aws s3 cp backup.gz s3://my-backups/platforma-backup.gz
```

Record the URI as MIGRATION_DATABASE_S3_URI in the variables block above.

### Step 0.5: Identify the Source Primary-Storage Bucket

If the source instance used S3 (not local disk) for primary storage, note its bucket name and region — they become MIGRATION_SOURCE_BUCKET and MIGRATION_SOURCE_REGION. The bucket is copied into the destination either by Step 0.6 (S3 Batch Replication, recommended for multi-TB buckets — start it now, finishes in the background) or by Step 1.3 (in-cluster s5cmd, for buckets up to ~1 TB). In the default full-freeze strategy, confirm the bucket is no longer being written to (Step 0.1) before starting either copy. In the **online** strategy (see *Migration Strategy* above) you deliberately start the copy while the source is still live and defer the freeze to the cutover window — the bulk copy then runs without blocking users.

### Step 0.6: S3 Batch Replication for Multi-TB Buckets

Use this path **instead of the in-cluster s5cmd sync (Step 1.3)** when the source bucket holds multiple TB or tens of millions of objects. S3 Batch Replication is an AWS-managed bulk copy that runs on the S3 service fleet rather than from a pod — throughput scales with the manifest size, not with your VPC bandwidth or pod CPU, and it can copy a multi-TB bucket in hours that would take days with a single s5cmd pod.

All steps run from a workstation with AWS CLI access to the cluster account. Kick the job off here — Batch Replication has no dependency on the Kubernetes cluster, so it copies in the background while you complete the rest of Phase 0 (DB dump) and Phase 1 (cluster setup, DB restore). The destination bucket must be fully populated **before helm install** in Phase 2; verify completion (Step 0.6.6) before moving on.

#### *Prerequisites*

| Requirement | Notes |
| :---- | :---- |
| **Versioning enabled on both buckets** | Replication operates on object versions. AWS rejects the replication config otherwise. |
| **Both buckets in the same AWS partition** | aws (commercial), aws-us-gov, etc. Cross-partition replication is not supported. |
| **Same-account or pre-configured cross-account trust** | For cross-account, the destination bucket policy must grant the source-account replication role s3:ReplicateObject, s3:ReplicateDelete, s3:ReplicateTags, s3:GetObjectVersionTagging, and s3:ObjectOwnerOverrideToBucketOwner. |
| **Manifest report bucket (optional but recommended)** | Batch Replication can generate the manifest on the fly; the completion report needs an S3 location to write to. Reuse the destination bucket with a reports/ prefix. |

#### *Step 0.6.1: Enable Versioning on Both Buckets*

```bash
aws s3api put-bucket-versioning \
  --bucket ${MIGRATION_SOURCE_BUCKET} \
  --region ${MIGRATION_SOURCE_REGION} \
  --versioning-configuration Status=Enabled
```

```bash
aws s3api put-bucket-versioning \
  --bucket ${S3_BUCKET} \
  --region ${REGION} \
  --versioning-configuration Status=Enabled
```

Versioning cannot be fully removed once enabled, only suspended. Suspending after the migration is fine — Platforma does not depend on versioning at runtime.

#### *Step 0.6.2: Create the Replication IAM Role*

This role is assumed by S3 itself when it copies each object. It needs read on the source and write on the destination.

```bash
# Trust policy — only s3.amazonaws.com can assume it
cat > /tmp/replication-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "s3.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
```

```bash
# Permissions policy
cat > /tmp/replication-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging",
        "s3:GetReplicationConfiguration",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}",
        "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags",
        "s3:ObjectOwnerOverrideToBucketOwner"
      ],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
    }
  ]
}
EOF
```

```bash
REPL_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-s3-replication \
  --assume-role-policy-document file:///tmp/replication-trust.json \
  --query 'Role.Arn' --output text)
```

```bash
aws iam put-role-policy \
  --role-name ${CLUSTER_NAME}-s3-replication \
  --policy-name s3-replication \
  --policy-document file:///tmp/replication-policy.json
```

```bash
echo "Replication role: $REPL_ROLE_ARN"
```

#### *Step 0.6.3 (Required before Step 0.6.5): Put a Replication Configuration on the Source Bucket*

S3 Batch Replication (Step 0.6.5) replicates each object **according to the bucket's replication configuration**, and the `EligibleForReplication: true` filter in that step matches objects against this config. So the replication configuration below is **required before the batch job, in either strategy**: without it the manifest generator finds zero eligible objects and the batch job completes having copied nothing — a silent failure caught only by the object-count check in Step 0.6.6.

Beyond enabling the batch job at all, the configuration also carries **live writes** to the destination, and that live-streaming matters differently per strategy:

* In the **full-freeze** strategy the live streaming is a bonus safety net — if anything accidentally writes to the supposedly-frozen source bucket during the migration window, those writes propagate to the destination instead of being orphaned.
* In the **online** strategy the live streaming is essential: applied *before* the backfill job, it streams the writes users make during the no-freeze window to the destination, so that by cutover only a tiny delta remains. Keep versioning enabled until cutover is complete.

The rule below replicates everything in the source bucket to the destination, owned by the destination account.

```bash
cat > /tmp/replication-config.json <<EOF
{
  "Role": "${REPL_ROLE_ARN}",
  "Rules": [{
    "ID": "platforma-migration",
    "Status": "Enabled",
    "Priority": 1,
    "Filter": {"Prefix": "${MIGRATION_SOURCE_PREFIX}"},
    "DeleteMarkerReplication": {"Status": "Disabled"},
    "Destination": {
      "Bucket": "arn:aws:s3:::${S3_BUCKET}",
      "AccessControlTranslation": {"Owner": "Destination"},
      "Account": "${AWS_ACCOUNT_ID}"
    }
  }]
}
EOF
```

```bash
aws s3api put-bucket-replication \
  --bucket ${MIGRATION_SOURCE_BUCKET} \
  --region ${MIGRATION_SOURCE_REGION} \
  --replication-configuration file:///tmp/replication-config.json
```

Note that this configuration alone does **not** copy existing objects — only objects written *after* it is applied are replicated live. The existing-object backfill is what Step 0.6.5 (the Batch Replication job) handles.

#### *Step 0.6.4: Create the Batch Operations IAM Role*

This role is assumed by S3 Batch Operations to drive the job — it needs to initiate replication and write the completion report.

```bash
cat > /tmp/batch-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "batchoperations.s3.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
```

```bash
cat > /tmp/batch-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:InitiateReplication"],
      "Resource": "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetReplicationConfiguration"],
      "Resource": "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/reports/*"
    }
  ]
}
EOF
```

```bash
BATCH_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-s3-batch-replication \
  --assume-role-policy-document file:///tmp/batch-trust.json \
  --query 'Role.Arn' --output text)
```

```bash
aws iam put-role-policy \
  --role-name ${CLUSTER_NAME}-s3-batch-replication \
  --policy-name s3-batch-replication \
  --policy-document file:///tmp/batch-policy.json
```

```bash
echo "Batch role: $BATCH_ROLE_ARN"
```

#### *Step 0.6.5: Create the Batch Replication Job*

Use auto-generated manifests — S3 inspects the source bucket and produces the manifest for you. No inventory report or pre-staged CSV needed.

```bash
cat > /tmp/batch-job.json <<EOF
{
  "ConfirmationRequired": false,
  "Operation": {
    "S3ReplicateObject": {}
  },
  "Report": {
    "Bucket": "arn:aws:s3:::${S3_BUCKET}",
    "Prefix": "reports/batch-replication",
    "Format": "Report_CSV_20180820",
    "Enabled": true,
    "ReportScope": "AllTasks"
  },
  "ManifestGenerator": {
    "S3JobManifestGenerator": {
      "SourceBucket": "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}",
      "EnableManifestOutput": false,
      "Filter": {
        "EligibleForReplication": true,
        "ObjectReplicationStatuses": ["NONE", "FAILED"]
      }
    }
  },
  "Priority": 10,
  "RoleArn": "${BATCH_ROLE_ARN}",
  "ClientRequestToken": "platforma-migration-$(date +%s)",
  "Description": "Platforma primary-storage migration"
}
EOF
```

```bash
JOB_ID=$(aws s3control create-job \
  --account-id ${AWS_ACCOUNT_ID} \
  --region ${MIGRATION_SOURCE_REGION} \
  --cli-input-json file:///tmp/batch-job.json \
  --query 'JobId' --output text)
```

```bash
echo "Batch job: $JOB_ID"
```

The ObjectReplicationStatuses: ["NONE", "FAILED"] filter ensures only un-replicated objects are processed — safe to re-run the job to retry failures.

#### *Step 0.6.6: Monitor the Job*

```bash
# Poll status
aws s3control describe-job \
  --account-id ${AWS_ACCOUNT_ID} \
  --region ${MIGRATION_SOURCE_REGION} \
  --job-id ${JOB_ID} \
  --query 'Job.{Status:Status,Progress:ProgressSummary}'
```

Or watch in the S3 console under **S3 → Batch Operations** — select the job to see objects-attempted / -succeeded / -failed in near real time. Typical throughput is hundreds of millions of objects per day; a 10-TB bucket of medium-sized objects usually completes in 6–12 hours.

Wait for Status: Complete and check the completion report at s3://${S3_BUCKET}/reports/batch-replication/job-${JOB_ID}/ — any per-object failures are listed there. The destination bucket key count should match the source.

#### *Step 0.6.7: Clean Up Replication Plumbing*

After the destination bucket is populated, remove the rule so the now-decommissioned source bucket isn't replicating anything new:

```bash
# Removes the entire replication configuration applied in Step 0.6.3
aws s3api delete-bucket-replication \
  --bucket ${MIGRATION_SOURCE_BUCKET} \
  --region ${MIGRATION_SOURCE_REGION}
```

```bash
# Optional: suspend versioning on the destination if Platforma will not use it
aws s3api put-bucket-versioning \
  --bucket ${S3_BUCKET} \
  --region ${REGION} \
  --versioning-configuration Status=Suspended
```

The IAM roles (*-s3-replication, *-s3-batch-replication) can be deleted or kept for future migrations.

---

## Phase 1: Pre-Helm

Goal: have a populated platforma-database PVC and a fully-synced primary-storage bucket **before** helm install runs, so that the chart's first-run reconciliation sees both a healthy database and the storage objects it references.

The primary-storage sync is the long-pole operation:

* **Multi-TB buckets** are handled by S3 Batch Replication in Step 0.6, kicked off back in Phase 0 and running in the background while Phase 1 proceeds. You can do all of Phase 1 in parallel with it — only verify completion before Phase 2.

* **Smaller buckets (< 1 TB)** are synced in-cluster by Step 1.3. Start that step first so it runs in parallel with the much faster DB download and restore (Steps 1.4–1.5).

Step 1.6 (cleanup) runs last.

### Step 1.1: Create Namespace, StorageClass, License Secret

```bash
kubectl create namespace ${NAMESPACE} 2>/dev/null || true
```

```bash
kubectl create secret generic platforma-license \
  -n ${NAMESPACE} \
  --from-literal=MI_LICENSE="${MI_LICENSE}"
```

If the cluster does not already have a gp3 StorageClass, create one. Labels and annotations let Helm adopt it later — without them, helm install fails with invalid ownership metadata.

```yaml
# gp3-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: platforma
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
```

```bash
kubectl apply -f gp3-storageclass.yaml
```

### Step 1.2: Pre-Create the Database PVC

The chart will adopt this PVC on install. Same labelling trick as the StorageClass.

```yaml
# database-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: platforma-database
  namespace: platforma
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: platforma
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
```

```bash
kubectl apply -f database-pvc.yaml
```

### Step 1.2.1: Recommended — IRSA Service Account for Migration Pods

Inline AWS keys in the pod YAML (MIGRATION_DB_ACCESS_KEY / MIGRATION_STORAGE_ACCESS_KEY) work for cross-account migrations, but for the **common case** where the dump bucket and the source primary-storage bucket live in the same AWS account as the cluster, attach an IRSA role to a dedicated service account and let the migration pods assume it. No long-lived keys, no Secret juggling.

The chart's runtime SAs (platforma, platforma-jobs) only have permissions on the *destination* bucket — they cannot read the source bucket, so reusing them does not work. Create a separate SA with read access to the source plus write access to the destination.

**Step A — IAM policy and role.** Run on a workstation with aws CLI access to the cluster account:

```bash
# Inline policy: read on source, read+write on destination
cat > /tmp/migration-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadSourceDump",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::$(echo ${MIGRATION_DATABASE_S3_URI} | awk -F/ '{print $3}')/*"
    },
    {
      "Sid": "ReadSourceStorage",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}",
        "arn:aws:s3:::${MIGRATION_SOURCE_BUCKET}/*"
      ]
    },
    {
      "Sid": "WriteDestination",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    }
  ]
}
EOF
```

```bash
aws iam create-policy \
  --policy-name ${CLUSTER_NAME}-migration-policy \
  --policy-document file:///tmp/migration-policy.json
```

```bash
# Trust policy for the OIDC provider
OIDC_ISSUER=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

```bash
cat > /tmp/migration-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:sub": "system:serviceaccount:${NAMESPACE}:platforma-migration",
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
```

```bash
MIGRATION_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-platforma-migration \
  --assume-role-policy-document file:///tmp/migration-trust.json \
  --query 'Role.Arn' --output text)
```

```bash
aws iam attach-role-policy \
  --role-name ${CLUSTER_NAME}-platforma-migration \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-migration-policy
```

```bash
echo "Migration role ARN: $MIGRATION_ROLE_ARN"
```

**Step B — Kubernetes service account.** The eks.amazonaws.com/role-arn annotation is what the EKS pod-identity webhook reads to inject AWS_WEB_IDENTITY_TOKEN_FILE into pods using this SA.

```yaml
# migration-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platforma-migration
  namespace: platforma
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/CLUSTER_NAME-platforma-migration
```

```bash
sed "s|ACCOUNT_ID|${AWS_ACCOUNT_ID}|; s|CLUSTER_NAME|${CLUSTER_NAME}|" migration-sa.yaml \
  | kubectl apply -f -
```

**Step C — reference the SA from every migration pod** by adding spec.serviceAccountName: platforma-migration (shown inline in the YAMLs below) and dropping the env: block with AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.

The same pattern works on GKE — replace the IAM role + annotation with a Workload Identity binding (iam.gke.io/gcp-service-account).

### Step 1.3: Sync Primary Storage (s5cmd, < 1 TB)

**Skip this step if you already started S3 Batch Replication in Step 0.6** — that path handles multi-TB buckets entirely on the AWS side. This step is the in-cluster alternative for buckets up to ~1 TB / 10 M objects, where running a pod is simpler than configuring Batch Replication.

Also skip if your source instance kept its primary storage on a local filesystem and you want the new cluster to start with an empty bucket.

| Bucket size | Use |
| :---- | :---- |
| **< ~1 TB / < 10 M objects** | This step (s5cmd in a pod) — simple, idempotent, runs alongside the other migration pods. |
| **≥ 1 TB or ≥ 10 M objects** | Step 0.6 (S3 Batch Replication) — kicked off in Phase 0, AWS-managed, runs in parallel with everything else. |

Platforma cannot serve any project that references objects in primary storage until those objects exist in the destination bucket — restoring the database alone is not enough. **Start this step before the database restore** so it runs in parallel with the much faster DB work in Steps 1.4–1.5.

The pod below uses [s5cmd](https://github.com/peak/s5cmd) instead of aws s3 sync. Both tools rely on S3 server-side COPY (no data leaves AWS, no egress charges) when source and destination are S3 buckets, but s5cmd parallelizes listing and copy operations aggressively — in practice **10–30× faster** than aws s3 sync for buckets with many small objects, which is the common shape of Platforma's primary storage.

```yaml
# mgr-sync.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-sync
  namespace: platforma
spec:
  serviceAccountName: platforma-migration   # IRSA SA from Step 1.2.1 — drop for cross-account
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  containers:
    - name: mgr-sync
      image: peakcom/s5cmd:v2.3.0
      command: ["/bin/sh", "-ec"]
      args:
        - |
          # --numworkers: parallel S3 operations (default 256 is fine; raise for very wide buckets).
          # sync uses server-side COPY when both sides are S3 — no bytes through this pod.
          # Trailing /* on the source is required by s5cmd to expand the prefix.
          # s5cmd sync is idempotent (ETag-compared), so re-running on completed buckets is cheap.
          s5cmd --numworkers 256 \
                --source-region ${MIGRATION_SOURCE_REGION} \
                --destination-region ${REGION} \
                sync "s3://${MIGRATION_SOURCE_BUCKET}/${MIGRATION_SOURCE_PREFIX}*" \
                     "s3://${S3_BUCKET}/"
          echo Storage sync complete
      # env section ONLY needed for cross-account source bucket — omit when using IRSA
      # env:
      #   - { name: AWS_ACCESS_KEY_ID,     value: "${MIGRATION_STORAGE_ACCESS_KEY}" }
      #   - { name: AWS_SECRET_ACCESS_KEY, value: "${MIGRATION_STORAGE_SECRET_KEY}" }
```

This pod intentionally does **not** mount the platforma-database PVC. The DB-handling pods (mgr-download, mgr-restore, mgr-invalidate) all mount that PVC with ReadWriteOnce access — Kubernetes would refuse to schedule mgr-sync to a different node while one of them is running. Skipping the mount lets mgr-sync run truly in parallel with the DB pipeline.

```bash
envsubst < mgr-sync.yaml | kubectl apply -f -
kubectl wait pod/mgr-sync -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=21600s
kubectl logs -f mgr-sync -n ${NAMESPACE}
kubectl delete pod/mgr-sync -n ${NAMESPACE}
```

Tuning notes:

* --numworkers controls the size of the worker pool. 256 saturates a single small pod on a same-region intra-AWS copy; raise to 1024 for very large buckets and bump pod CPU requests accordingly.

* s5cmd sync is idempotent — it compares object size/ETag and skips unchanged keys, so reruns after a failure resume cheaply.

* s5cmd does not attempt to copy ACLs or object tags, so the aws s3 sync ... --copy-props none workaround used previously for cross-account migrations is unnecessary here.

* MIGRATION_SOURCE_PREFIX should end with / if set (e.g. data/). Without a trailing slash, the ${MIGRATION_SOURCE_PREFIX}* glob would match sibling prefixes too — e.g. prefix data matches both data/ and data2/.

### Step 1.4: Download the Database Dump

```yaml
# mgr-download.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-download
  namespace: platforma
spec:
  serviceAccountName: platforma-migration   # IRSA SA from Step 1.2.1 — drop this for cross-account
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: platforma-database
  containers:
    - name: mgr-download
      image: amazon/aws-cli:2.27.22
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          aws s3 cp ${MIGRATION_DATABASE_S3_URI} /data/database/backup.gz
          echo Download complete
      # env section ONLY needed for cross-account dumps — omit when using IRSA
      # env:
      #   - { name: AWS_ACCESS_KEY_ID,     value: "${MIGRATION_DB_ACCESS_KEY}" }
      #   - { name: AWS_SECRET_ACCESS_KEY, value: "${MIGRATION_DB_SECRET_KEY}" }
      volumeMounts:
        - { name: db, mountPath: /data/database }
```

When using the platforma-migration SA from Step 1.2.1, the pod assumes the IAM role transparently — no env: block needed. For cross-account dumps that the SA's role does not cover, uncomment the env: block and inline the access keys (or mount them from a Secret).

```bash
envsubst < mgr-download.yaml | kubectl apply -f -
kubectl wait pod/mgr-download -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
kubectl logs mgr-download -n ${NAMESPACE}
kubectl delete pod/mgr-download -n ${NAMESPACE}
```

### Step 1.5: Restore the Database

```yaml
# mgr-restore.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-restore
  namespace: platforma
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - { name: db,   persistentVolumeClaim: { claimName: platforma-database } }
    - { name: main, emptyDir: {} }
  containers:
    - name: mgr-restore
      image: quay.io/milaboratories/platforma:${PLATFORMA_VERSION}
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          /app/platforma --restore-db=/data/database/backup.gz --db-dir=/data/database --force
          echo Database restored
      env:
        - name: PL_LICENSE
          valueFrom:
            secretKeyRef: { name: platforma-license, key: MI_LICENSE }
      volumeMounts:
        - { name: db,   mountPath: /data/database }
        - { name: main, mountPath: /data/main }
```

```bash
envsubst < mgr-restore.yaml | kubectl apply -f -
kubectl wait pod/mgr-restore -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=1800s
kubectl logs mgr-restore -n ${NAMESPACE}
kubectl delete pod/mgr-restore -n ${NAMESPACE}
```

--force overwrites any partial DB from a previous attempt. Restore time scales with dump size — give a generous timeout (default 30 min above; bump to several hours for multi-hundred-GB dumps).

### Step 1.6: Delete the Dump File

```bash
kubectl run mgr-cleanup -n ${NAMESPACE} --restart=Never \
  --image=amazon/aws-cli:2.27.22 \
  --overrides='{"spec":{"securityContext":{"fsGroup":1010,"runAsUser":1010,"runAsGroup":1010},"containers":[{"name":"mgr-cleanup","image":"amazon/aws-cli:2.27.22","command":["sh","-ec","if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi; rm -f /data/database/backup.gz"],"volumeMounts":[{"name":"db","mountPath":"/data/database"}]}],"volumes":[{"name":"db","persistentVolumeClaim":{"claimName":"platforma-database"}}]}}'
kubectl wait pod/mgr-cleanup -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl delete pod/mgr-cleanup -n ${NAMESPACE}
```

---

## Phase 2: Helm Install

Standard install — see [README.md](README.md) and [advanced-installation.md](cloudformation/advanced-installation.md) Step 10. The chart adopts the pre-existing PVC and StorageClass and starts the Platforma server. On first start the server applies any in-binary schema migrations against the restored DB.

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version ${CHART_VERSION} \
  -n ${NAMESPACE} \
  -f infrastructure/aws/values-aws-s3.yaml \
  --set storage.main.s3.bucket=${S3_BUCKET} \
  --set storage.main.s3.region=${REGION} \
  ...   # other --set flags from advanced-installation.md Step 10
```

Wait for the rollout to settle:

```bash
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=platforma -n ${NAMESPACE} --timeout=300s
```

---

## Phase 3: Post-Helm (Cache Invalidation)

This step switches the **execution backend**, not the storage bucket. The single-server source ran analysis software through a **local run environment** — software installed and executed on the server's own disk. On Kubernetes, software runs in **Docker** containers instead. The restored database still holds cached results bound to that old local run environment, which does not exist on the cluster. `--invalidate-caches` discards those cached results so that every piece of software re-resolves and re-runs through the cluster's Docker executor.

This is unrelated to the storage bucket. The database references primary-storage objects by **relative path plus a storage ID** (not by absolute bucket URL), so pointing the cluster at the new bucket is purely a Helm config change (`storage.main.s3.bucket` in Phase 2) and needs no rewrite. Cache invalidation is required because the *executor* changed (local → Docker), and it would be required even if the bucket name had stayed the same.

The Platforma binary that runs invalidation needs exclusive RWO access to the database PVC, so we briefly scale the server down to zero.

### Step 3.1: Scale Platforma Down

```bash
kubectl scale deployment/platforma -n ${NAMESPACE} --replicas=0
kubectl wait --for=delete pod -l app.kubernetes.io/name=platforma \
  -n ${NAMESPACE} --timeout=120s
```

### Step 3.2: Run Invalidation

```yaml
# mgr-invalidate.yaml
apiVersion: v1
kind: Pod
metadata:
  name: mgr-invalidate
  namespace: platforma
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - { name: db,   persistentVolumeClaim: { claimName: platforma-database } }
    - { name: main, emptyDir: {} }
  containers:
    - name: mgr-invalidate
      image: quay.io/milaboratories/platforma:${PLATFORMA_VERSION}
      command: ["/bin/sh", "-ec"]
      args:
        - |
          if [ -f /data/database/.migration-complete ]; then echo Already completed; exit 0; fi
          /app/platforma --invalidate-caches --main-root=/data/main --db-dir=/data/database
          date -u > /data/database/.migration-complete
          echo Caches invalidated
      env:
        - name: PL_LICENSE
          valueFrom:
            secretKeyRef: { name: platforma-license, key: MI_LICENSE }
      volumeMounts:
        - { name: db,   mountPath: /data/database }
        - { name: main, mountPath: /data/main }
```

```bash
envsubst < mgr-invalidate.yaml | kubectl apply -f -
kubectl wait pod/mgr-invalidate -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=1800s
kubectl logs mgr-invalidate -n ${NAMESPACE}
kubectl delete pod/mgr-invalidate -n ${NAMESPACE}
```

The marker file /data/database/.migration-complete makes this step and every other PVC-mounting step (1.4 download, 1.5 restore, 1.6 cleanup) a no-op on re-run. Step 1.3 (s5cmd) and the Phase 0 AWS-side steps are not marker-gated — see the **Re-Running Steps After a Failure** section above for how they handle re-runs.

### Step 3.3: Scale Platforma Back Up

```bash
kubectl scale deployment/platforma -n ${NAMESPACE} --replicas=1
kubectl rollout status deployment/platforma -n ${NAMESPACE} --timeout=300s
```

---

## Verification

```bash
kubectl get pvc -n ${NAMESPACE}                # platforma-database Bound, > 0 used
kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=platforma | grep -i 'ready\|migration'
aws s3 ls s3://${S3_BUCKET}/ --summarize       # object count matches source
```

Connect from the Desktop App; existing projects, results, and credentials should appear.

---

## Cross-Account Sync

If the source S3 bucket lives in a different AWS account, the destination bucket policy must grant the source identity write access. Pattern: create an IAM user (or role) in the **source** account, generate access keys, and add a bucket policy on the **destination** bucket like:

```bash
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<source-account>:user/migration-user" },
    "Action": ["s3:PutObject", "s3:ListBucket", "s3:AbortMultipartUpload"],
    "Resource": [
      "arn:aws:s3:::${S3_BUCKET}",
      "arn:aws:s3:::${S3_BUCKET}/*"
    ]
  }]
}
```

Then export the access keys as MIGRATION_STORAGE_ACCESS_KEY / MIGRATION_STORAGE_SECRET_KEY (Step 1.3). The same pattern applies to the database-dump bucket (MIGRATION_DB_*).

---

## Rollback

If the migration fails after helm install:

1. helm uninstall platforma -n ${NAMESPACE} — removes the Deployment but **keeps PVCs by default**. Verify with kubectl get pvc -n ${NAMESPACE}.

2. kubectl delete pvc platforma-database -n ${NAMESPACE} — wipe the bad DB.

3. Repeat Phase 1 with the same dump.

The source single-server instance is modified only by the block cancellation in Step 0.3.2 (and the debug-API restart in Step 0.2). The safety backup taken in Step 0.3.1 — `backup-pre-cancel.gz` — captures its state before that cancellation, so you can restore the old instance to its pre-cutover state if you need to roll back. Otherwise the source is left untouched; keep it running until you have validated the new cluster.
