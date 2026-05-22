# Migration: Single-Server Platforma → Kubernetes

End-to-end procedure to move an existing single-server Platforma instance (running the standalone binary or Docker image) onto a Kubernetes cluster managed by this Helm chart.

The migration moves two pieces of state:

1. **Database** — RocksDB on the source server, dumped to a gzipped file and restored into the chart's `platforma-database` PVC.
2. **Primary storage** — bucket-to-bucket S3 sync (or equivalent on GCP) into the new cloud bucket the cluster will use.

The procedure is split into three phases that run before, during, and after the `helm install`. Phase 3 writes a `/data/database/.migration-complete` marker on the database PVC after cache invalidation succeeds; every PVC-bound in-cluster step (DB download, restore, invalidate, dump cleanup) gates on this marker, so re-running them once the migration has completed end-to-end is a no-op. Phase 0 steps (DB dump on the source, S3 Batch Replication kickoff) and Step 1.3 (`s5cmd` sync) are idempotent by virtue of the underlying operation — re-running a finished DB dump just overwrites the local file, re-creating a Batch Replication job is rejected by the `ClientRequestToken`, and `s5cmd sync` skips already-copied objects via ETag comparison.

## Audience and Scope

This guide is written for an operator standing up the target cluster with **Terraform** (or any IaC equivalent of `eksctl` / CloudFormation). It assumes:

- You have provisioned the target cluster's infrastructure following the resources listed in [`infrastructure/aws/advanced-installation.md`](infrastructure/aws/advanced-installation.md) — that doc enumerates every IAM policy, IRSA role, S3 bucket, EFS filesystem, ACM certificate, and StorageClass that the Helm chart depends on. Translate each `aws ...` call into the equivalent Terraform resource.
- You have `kubectl` access to the cluster and admin permissions in the target namespace (`platforma` by default).
- You have AWS CLI access to both the **source** primary-storage S3 bucket (read) and the **destination** bucket (write). Cross-account migrations need an extra IAM user — see [Cross-Account Sync](#cross-account-sync) below.

If you are setting up the cluster from scratch on AWS using CloudFormation, the same migration is wired into [`cloudformation-eks-1-35.yaml`](infrastructure/aws/cloudformation-eks-1-35.yaml) via the `MigrationDatabaseS3Uri` / `MigrationSourceBucket` parameters. This guide is the manual equivalent.

## Prerequisites

| Requirement | Notes |
|---|---|
| Source Platforma version | Same major.minor as the target chart's image. Cross-version restore is not supported. |
| Source database dump | Created with `curl -s http://localhost:9091/db/state_raw \| gzip > backup.gz`, then uploaded to S3. The endpoint is part of the debug API — it requires `--debug-enabled` (or `PL_DEBUG_ENABLED=true`) on the source server, and binds to `127.0.0.1:9091` by default. See [Phase 0](#phase-0-source-side-preparation). |
| Target cluster ready | Cluster Autoscaler, Kueue + AppWrapper, EFS CSI, EBS CSI, S3 IRSA all working. See [advanced-installation.md](infrastructure/aws/advanced-installation.md) Steps 1–8. |
| Target S3 bucket created | Empty. The migration will sync data into it. |
| `MI_LICENSE` available | The migration uses the Platforma image to run `--restore-db` and `--invalidate-caches`, both of which need a valid license. |
| `kubectl` and AWS CLI | Configured for the target cluster and account. |
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

# Platforma image tag used by the migration pods (must match the source server's major.minor)
export PLATFORMA_VERSION="3.0.1"
# Helm chart version installed in Phase 2 — usually tracks PLATFORMA_VERSION but can differ
export CHART_VERSION="${PLATFORMA_VERSION}"

# License — required by the Platforma-image pods (restore + invalidate)
export MI_LICENSE="..."                                # paste the license token, or load from a file

# Source dump (required)
export MIGRATION_DATABASE_S3_URI="s3://my-backups/platforma-backup.gz"

# Source primary storage (optional — omit to skip storage sync)
export MIGRATION_SOURCE_BUCKET="old-platforma-bucket"
export MIGRATION_SOURCE_PREFIX=""              # leave empty for bucket root
export MIGRATION_SOURCE_REGION="eu-west-1"     # defaults to $REGION if empty

# Cross-account credentials (optional)
export MIGRATION_DB_ACCESS_KEY=""              # AKIA... — needed if dump is in another account
export MIGRATION_DB_SECRET_KEY=""
export MIGRATION_STORAGE_ACCESS_KEY=""         # AKIA... — needed if source bucket is in another account
export MIGRATION_STORAGE_SECRET_KEY=""
```

## Architecture of the Migration Job

All migration work runs as one-shot pods inside the target namespace. They use:

- The official Platforma image (`quay.io/milaboratories/platforma:${PLATFORMA_VERSION}`) for DB restore and cache invalidation.
- The `amazon/aws-cli:2.27.22` image for S3 download/sync.
- Pod `securityContext`: `fsGroup: 1010`, `runAsUser: 1010`, `runAsGroup: 1010` (matches the chart's non-root `pl` user — UID/GID **must** be 1010 or restored RocksDB files will be unreadable by the server pod).
- The `platforma-database` PVC (RWO, 50Gi, gp3) mounted at `/data/database`.
- The `platforma-license` Secret for the Platforma-image pods.

The reference implementation is the script at [`infrastructure/aws/migration.sh`](infrastructure/aws/migration.sh). The YAML below is what that script generates and applies — provided here so you can run the migration manually or wire it into your own Terraform `null_resource` / `helm_release` `provisioner`.

---

## Phase 0: Source-Side Preparation

Steps 0.1–0.5 run on the **source** single-server host (the machine running the standalone binary or Docker image). Step 0.6 runs from a workstation with AWS CLI access — it is entirely AWS-side and has no dependency on the target Kubernetes cluster, so kicking it off here lets AWS copy data in the background while you complete the rest of Phase 0 and all of Phase 1.

Phase 0 produces:

1. A gzipped database dump uploaded to S3 (referenced by `MIGRATION_DATABASE_S3_URI`).
2. A frozen primary-storage S3 bucket whose name you record as `MIGRATION_SOURCE_BUCKET`.
3. For multi-TB buckets: a running S3 Batch Replication job that will populate the destination bucket before Phase 2.

### Step 0.1: Freeze the Source Instance

Stop all writes — pause Desktop App users and any automated submitters. The database dump and the storage bucket must represent the same point in time; new objects written after the dump is taken will be invisible to the restored DB and orphaned in storage.

### Step 0.2: Enable the Debug API on the Source

The `/db/state_raw` endpoint is gated behind the debug API. If it is not already enabled, restart the source server with `--debug-enabled` (or set `PL_DEBUG_ENABLED=true`). The endpoint binds to `127.0.0.1:9091` by default — run the dump command **on the source host itself**, or temporarily change `--debug-ip` to bind to a routable interface.

Verify:

```bash
curl -sf http://localhost:9091/db/stats >/dev/null && echo "debug API reachable"
```

### Step 0.3: Dump the Database

```bash
curl -s http://localhost:9091/db/state_raw | gzip > backup.gz
```

The endpoint streams a tab-separated key/value dump of RocksDB; piping into `gzip` writes a single compressed file. Dump time scales with DB size — a 10 GB live DB typically compresses to 1–3 GB.

> The same dump can also be produced offline with the `pl-db-cli` binary that ships in the Platforma image (`/app/pl-db-cli dump --db-dir=...`) if the source server cannot expose the debug API.

### Step 0.4: Upload the Dump to S3

Use whatever S3 bucket the new cluster can read from. For same-account migrations, any bucket the migration IRSA role can `s3:GetObject` from works — that role is defined later in [Step 1.2.1](#step-121-recommended--irsa-service-account-for-migration-pods), so make sure the bucket you choose here will be covered by the policy you attach there.

```bash
aws s3 cp backup.gz s3://my-backups/platforma-backup.gz
```

Record the URI as `MIGRATION_DATABASE_S3_URI` in the variables block above.

### Step 0.5: Identify the Source Primary-Storage Bucket

If the source instance used S3 (not local disk) for primary storage, note its bucket name and region — they become `MIGRATION_SOURCE_BUCKET` and `MIGRATION_SOURCE_REGION`. The bucket is copied into the destination either by [Step 0.6](#step-06-s3-batch-replication-for-multi-tb-buckets) (S3 Batch Replication, recommended for multi-TB buckets — start it now, finishes in the background) or by [Step 1.3](#step-13-sync-primary-storage-s5cmd--1-tb) (in-cluster `s5cmd`, for buckets up to ~1 TB). Confirm the bucket is no longer being written to (Step 0.1) before starting either.

### Step 0.6: S3 Batch Replication for Multi-TB Buckets

Use this path **instead of the in-cluster `s5cmd` sync (Step 1.3)** when the source bucket holds multiple TB or tens of millions of objects. S3 Batch Replication is an AWS-managed bulk copy that runs on the S3 service fleet rather than from a pod — throughput scales with the manifest size, not with your VPC bandwidth or pod CPU, and it can copy a multi-TB bucket in hours that would take days with a single `s5cmd` pod.

All steps run from a workstation with AWS CLI access to the cluster account. Kick the job off here — Batch Replication has no dependency on the Kubernetes cluster, so it copies in the background while you complete the rest of Phase 0 (DB dump) and Phase 1 (cluster setup, DB restore). The destination bucket must be fully populated **before `helm install`** in Phase 2; verify completion (Step 0.6.6) before moving on.

#### Prerequisites

| Requirement | Notes |
|---|---|
| **Versioning enabled on both buckets** | Replication operates on object versions. AWS rejects the replication config otherwise. |
| **Both buckets in the same AWS partition** | `aws` (commercial), `aws-us-gov`, etc. Cross-partition replication is not supported. |
| **Same-account or pre-configured cross-account trust** | For cross-account, the destination bucket policy must grant the source-account replication role `s3:ReplicateObject`, `s3:ReplicateDelete`, `s3:ReplicateTags`, `s3:GetObjectVersionTagging`, and `s3:ObjectOwnerOverrideToBucketOwner`. |
| **Manifest report bucket (optional but recommended)** | Batch Replication can generate the manifest on the fly; the completion report needs an S3 location to write to. Reuse the destination bucket with a `reports/` prefix. |

#### Step 0.6.1: Enable Versioning on Both Buckets

```bash
aws s3api put-bucket-versioning \
  --bucket ${MIGRATION_SOURCE_BUCKET} \
  --region ${MIGRATION_SOURCE_REGION} \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-versioning \
  --bucket ${S3_BUCKET} \
  --region ${REGION} \
  --versioning-configuration Status=Enabled
```

Versioning cannot be fully removed once enabled, only suspended. Suspending after the migration is fine — Platforma does not depend on versioning at runtime.

#### Step 0.6.2: Create the Replication IAM Role

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

REPL_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-s3-replication \
  --assume-role-policy-document file:///tmp/replication-trust.json \
  --query 'Role.Arn' --output text)

aws iam put-role-policy \
  --role-name ${CLUSTER_NAME}-s3-replication \
  --policy-name s3-replication \
  --policy-document file:///tmp/replication-policy.json

echo "Replication role: $REPL_ROLE_ARN"
```

#### Step 0.6.3 (Optional, Recommended): Put a Replication Configuration on the Source Bucket

The Batch job in Step 0.6.5 generates its own manifest and can copy existing objects without a bucket-level replication configuration. The reason to put one on anyway is to act as a safety net: if anything accidentally writes to the supposedly-frozen source bucket during the migration window, those writes propagate live to the destination instead of being orphaned. Skip this step only if you are certain no writes can occur on the source.

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

aws s3api put-bucket-replication \
  --bucket ${MIGRATION_SOURCE_BUCKET} \
  --region ${MIGRATION_SOURCE_REGION} \
  --replication-configuration file:///tmp/replication-config.json
```

Note that this configuration alone does **not** copy existing objects — only objects written *after* it is applied are replicated live. The existing-object backfill is what Step 0.6.5 (the Batch Replication job) handles.

#### Step 0.6.4: Create the Batch Operations IAM Role

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
      "Action": [
        "s3:GetReplicationConfiguration",
        "s3:PutInventoryConfiguration"
      ],
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

BATCH_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-s3-batch-replication \
  --assume-role-policy-document file:///tmp/batch-trust.json \
  --query 'Role.Arn' --output text)

aws iam put-role-policy \
  --role-name ${CLUSTER_NAME}-s3-batch-replication \
  --policy-name s3-batch-replication \
  --policy-document file:///tmp/batch-policy.json

echo "Batch role: $BATCH_ROLE_ARN"
```

#### Step 0.6.5: Create the Batch Replication Job

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

JOB_ID=$(aws s3control create-job \
  --account-id ${AWS_ACCOUNT_ID} \
  --region ${MIGRATION_SOURCE_REGION} \
  --cli-input-json file:///tmp/batch-job.json \
  --query 'JobId' --output text)

echo "Batch job: $JOB_ID"
```

The `ObjectReplicationStatuses: ["NONE", "FAILED"]` filter ensures only un-replicated objects are processed — safe to re-run the job to retry failures.

#### Step 0.6.6: Monitor the Job

```bash
# Poll status
aws s3control describe-job \
  --account-id ${AWS_ACCOUNT_ID} \
  --region ${MIGRATION_SOURCE_REGION} \
  --job-id ${JOB_ID} \
  --query 'Job.{Status:Status,Progress:ProgressSummary}'
```

Or watch in the S3 console under **S3 → Batch Operations** — select the job to see objects-attempted / -succeeded / -failed in near real time. Typical throughput is hundreds of millions of objects per day; a 10-TB bucket of medium-sized objects usually completes in 6–12 hours.

Wait for `Status: Complete` and check the completion report at `s3://${S3_BUCKET}/reports/batch-replication/job-${JOB_ID}/` — any per-object failures are listed there. The destination bucket key count should match the source.

#### Step 0.6.7: Clean Up Replication Plumbing

After the destination bucket is populated, remove the rule so the now-decommissioned source bucket isn't replicating anything new:

```bash
# Removes the entire replication configuration applied in Step 0.6.3
aws s3api delete-bucket-replication \
  --bucket ${MIGRATION_SOURCE_BUCKET} \
  --region ${MIGRATION_SOURCE_REGION}

# Optional: suspend versioning on the destination if Platforma will not use it
aws s3api put-bucket-versioning \
  --bucket ${S3_BUCKET} \
  --region ${REGION} \
  --versioning-configuration Status=Suspended
```

The IAM roles (`*-s3-replication`, `*-s3-batch-replication`) can be deleted or kept for future migrations.

---

## Phase 1: Pre-Helm

Goal: have a populated `platforma-database` PVC and a fully-synced primary-storage bucket **before** `helm install` runs, so that the chart's first-run reconciliation sees both a healthy database and the storage objects it references.

The primary-storage sync is the long-pole operation:

- **Multi-TB buckets** are handled by S3 Batch Replication in [Step 0.6](#step-06-s3-batch-replication-for-multi-tb-buckets), kicked off back in Phase 0 and running in the background while Phase 1 proceeds. You can do all of Phase 1 in parallel with it — only verify completion before Phase 2.
- **Smaller buckets (< 1 TB)** are synced in-cluster by [Step 1.3](#step-13-sync-primary-storage-s5cmd--1-tb). Start that step first so it runs in parallel with the much faster DB download and restore (Steps 1.4–1.5).

Step 1.6 (cleanup) runs last.

### Step 1.1: Create Namespace, StorageClass, License Secret

```bash
kubectl create namespace ${NAMESPACE} 2>/dev/null || true

kubectl create secret generic platforma-license \
  -n ${NAMESPACE} \
  --from-literal=MI_LICENSE="${MI_LICENSE}"
```

If the cluster does not already have a `gp3` StorageClass, create one. Labels and annotations let Helm adopt it later — without them, `helm install` fails with `invalid ownership metadata`.

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

Inline AWS keys in the pod YAML (`MIGRATION_DB_ACCESS_KEY` / `MIGRATION_STORAGE_ACCESS_KEY`) work for cross-account migrations, but for the **common case** where the dump bucket and the source primary-storage bucket live in the same AWS account as the cluster, attach an IRSA role to a dedicated service account and let the migration pods assume it. No long-lived keys, no Secret juggling.

The chart's runtime SAs (`platforma`, `platforma-jobs`) only have permissions on the *destination* bucket — they cannot read the source bucket, so reusing them does not work. Create a separate SA with read access to the source plus write access to the destination.

**Step A — IAM policy and role.** Run on a workstation with `aws` CLI access to the cluster account:

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

aws iam create-policy \
  --policy-name ${CLUSTER_NAME}-migration-policy \
  --policy-document file:///tmp/migration-policy.json

# Trust policy for the OIDC provider
OIDC_ISSUER=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

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

MIGRATION_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-platforma-migration \
  --assume-role-policy-document file:///tmp/migration-trust.json \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name ${CLUSTER_NAME}-platforma-migration \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-migration-policy

echo "Migration role ARN: $MIGRATION_ROLE_ARN"
```

**Step B — Kubernetes service account.** The `eks.amazonaws.com/role-arn` annotation is what the EKS pod-identity webhook reads to inject `AWS_WEB_IDENTITY_TOKEN_FILE` into pods using this SA.

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

**Step C — reference the SA from every migration pod** by adding `spec.serviceAccountName: platforma-migration` (shown inline in the YAMLs below) and dropping the `env:` block with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.

> The same pattern works on GKE — replace the IAM role + annotation with a Workload Identity binding (`iam.gke.io/gcp-service-account`).

### Step 1.3: Sync Primary Storage (`s5cmd`, < 1 TB)

**Skip this step if you already started S3 Batch Replication in [Step 0.6](#step-06-s3-batch-replication-for-multi-tb-buckets)** — that path handles multi-TB buckets entirely on the AWS side. This step is the in-cluster alternative for buckets up to ~1 TB / 10 M objects, where running a pod is simpler than configuring Batch Replication.

Also skip if your source instance kept its primary storage on a local filesystem and you want the new cluster to start with an empty bucket.

| Bucket size | Use |
|---|---|
| **< ~1 TB / < 10 M objects** | This step (`s5cmd` in a pod) — simple, idempotent, runs alongside the other migration pods. |
| **≥ 1 TB or ≥ 10 M objects** | [Step 0.6](#step-06-s3-batch-replication-for-multi-tb-buckets) (S3 Batch Replication) — kicked off in Phase 0, AWS-managed, runs in parallel with everything else. |

Platforma cannot serve any project that references objects in primary storage until those objects exist in the destination bucket — restoring the database alone is not enough. **Start this step before the database restore** so it runs in parallel with the much faster DB work in Steps 1.4–1.5.

The pod below uses [`s5cmd`](https://github.com/peak/s5cmd) instead of `aws s3 sync`. Both tools rely on S3 server-side COPY (no data leaves AWS, no egress charges) when source and destination are S3 buckets, but `s5cmd` parallelizes listing and copy operations aggressively — in practice **10–30× faster** than `aws s3 sync` for buckets with many small objects, which is the common shape of Platforma's primary storage.

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
          AWS_REGION=${REGION} \
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

This pod intentionally does **not** mount the `platforma-database` PVC. The DB-handling pods (`mgr-download`, `mgr-restore`, `mgr-invalidate`) all mount that PVC with `ReadWriteOnce` access — k8s would refuse to schedule `mgr-sync` to a different node while one of them is running. Skipping the mount lets `mgr-sync` run truly in parallel with the DB pipeline.

```bash
envsubst < mgr-sync.yaml | kubectl apply -f -
kubectl wait pod/mgr-sync -n ${NAMESPACE} \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=86400s
kubectl logs -f mgr-sync -n ${NAMESPACE}
kubectl delete pod/mgr-sync -n ${NAMESPACE}
```

Tuning notes:

- `--numworkers` controls the size of the worker pool. 256 saturates a single small pod on a same-region intra-AWS copy; raise to 1024 for very large buckets and bump pod CPU requests accordingly.
- `s5cmd sync` is idempotent — it compares object size/ETag and skips unchanged keys, so reruns after a failure resume cheaply.
- `s5cmd` does not attempt to copy ACLs or object tags, so the `aws s3 sync ... --copy-props none` workaround used previously for cross-account migrations is unnecessary here.
- `MIGRATION_SOURCE_PREFIX` should end with `/` if set (e.g. `data/`). Without a trailing slash, the `${MIGRATION_SOURCE_PREFIX}*` glob would match sibling prefixes too — e.g. prefix `data` matches both `data/` and `data2/`.

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

When using the `platforma-migration` SA from Step 1.2.1, the pod assumes the IAM role transparently — no `env:` block needed. For cross-account dumps that the SA's role does not cover, uncomment the `env:` block and inline the access keys (or mount them from a Secret).

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

`--force` overwrites any partial DB from a previous attempt. Restore time scales with dump size — give a generous timeout (default 30 min above; bump to several hours for multi-hundred-GB dumps).

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

Standard install — see [`README.md`](README.md) and [`advanced-installation.md`](infrastructure/aws/advanced-installation.md) Step 10. The chart adopts the pre-existing PVC and StorageClass and starts the Platforma server. On first start the server applies any in-binary schema migrations against the restored DB.

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

After the chart's first reconciliation, internal caches in the restored DB still point at the **old** primary-storage URLs. Invalidating them rewrites those references to the new bucket.

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

The marker file `/data/database/.migration-complete` makes this and every previous step a no-op on re-run.

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

```json
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

Then export the access keys as `MIGRATION_STORAGE_ACCESS_KEY` / `MIGRATION_STORAGE_SECRET_KEY` (Step 1.3). The same pattern applies to the database-dump bucket (`MIGRATION_DB_*`).

---

## Rollback

If the migration fails after `helm install`:

1. `helm uninstall platforma -n ${NAMESPACE}` — removes the Deployment but **keeps PVCs by default**. Verify with `kubectl get pvc -n ${NAMESPACE}`.
2. `kubectl delete pvc platforma-database -n ${NAMESPACE}` — wipe the bad DB.
3. Repeat Phase 1 with the same dump.

Apart from the debug-API restart in [Step 0.2](#step-02-enable-the-debug-api-on-the-source), the source single-server instance is untouched throughout — keep it running until you have validated the new cluster.

