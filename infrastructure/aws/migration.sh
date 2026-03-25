#!/usr/bin/env bash
# =============================================================================
# Platforma data migration script
# =============================================================================
# Restores a Platforma database from a dump and optionally syncs primary
# storage from an existing S3 bucket. Runs as kubectl pods inside the
# target EKS cluster.
#
# Required environment variables:
#   NAMESPACE                   - Kubernetes namespace
#   REGION                      - AWS region
#   S3_BUCKET                   - Destination S3 bucket (created by CF)
#   PLATFORMA_VERSION           - Platforma version (used for image tag)
#   MIGRATION_DATABASE_S3_URI   - S3 URI to database dump (e.g. s3://bucket/backup.gz)
#
# Optional environment variables:
#   PLATFORMA_IMAGE             - Custom platforma image (overrides default)
#   MIGRATION_DB_ACCESS_KEY     - AWS access key for database dump bucket
#   MIGRATION_DB_SECRET_KEY     - AWS secret key for database dump bucket
#   MIGRATION_SOURCE_BUCKET     - Source primary storage bucket (enables sync)
#   MIGRATION_SOURCE_PREFIX     - Prefix within source bucket
#   MIGRATION_SOURCE_REGION     - Source bucket region (defaults to REGION)
#   MIGRATION_STORAGE_ACCESS_KEY - AWS access key for source storage bucket
#   MIGRATION_STORAGE_SECRET_KEY - AWS secret key for source storage bucket
# =============================================================================
set -euo pipefail

if [ -z "${MIGRATION_DATABASE_S3_URI:-}" ]; then
  echo "MIGRATION_DATABASE_S3_URI not set, skipping migration"
  exit 0
fi

echo "=== Platforma data migration ==="

# Configuration
PVC="platforma-database"
DB_DIR="/data/database"
MARKER="$DB_DIR/.migration-complete"
PL_IMG="${PLATFORMA_IMAGE:-quay.io/milaboratories/platforma:${PLATFORMA_VERSION}}"
AWS_IMG="amazon/aws-cli:2.27.22"
SEC_CTX='{"fsGroup":1010,"runAsUser":1010,"runAsGroup":1010}'
VOLS='[{"name":"db","persistentVolumeClaim":{"claimName":"'$PVC'"}}]'
MNTS='[{"name":"db","mountPath":"'$DB_DIR'"}]'

# Helper: run a pod, stream logs, wait for success, cleanup
run_pod() {
  local name="$1" image="$2" script="$3" env_json="$4" timeout="$5"

  echo "  Starting pod: $name"
  kubectl delete pod/"$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null

  cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  securityContext: $SEC_CTX
  restartPolicy: Never
  volumes: $VOLS
  containers:
  - name: $name
    image: $image
    command: ["/bin/sh", "-ec"]
    args:
    - |
      $script
    env: $env_json
    volumeMounts: $MNTS
EOF

  kubectl wait pod/"$name" -n "$NAMESPACE" --for=condition=Ready --timeout=120s 2>/dev/null || true
  kubectl logs -f "$name" -n "$NAMESPACE" || true
  kubectl wait pod/"$name" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${timeout}s"
  kubectl delete pod/"$name" -n "$NAMESPACE"
  echo "  Pod $name completed"
}

# Ensure database PVC exists (helm may not have run yet)
if ! kubectl get pvc "$PVC" -n "$NAMESPACE" 2>/dev/null; then
  echo "Creating database PVC..."
  cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
EOF
fi

# Build env JSON for credentials
DB_ENV="[]"
if [ -n "${MIGRATION_DB_ACCESS_KEY:-}" ]; then
  DB_ENV='[{"name":"AWS_ACCESS_KEY_ID","value":"'"$MIGRATION_DB_ACCESS_KEY"'"},{"name":"AWS_SECRET_ACCESS_KEY","value":"'"$MIGRATION_DB_SECRET_KEY"'"}]'
fi

LIC_ENV='[{"name":"PL_LICENSE","valueFrom":{"secretKeyRef":{"name":"platforma-license","key":"MI_LICENSE"}}}]'

# Step 1: Download database dump
echo "--- Step 1/4: Downloading database dump ---"
run_pod mgr-download "$AWS_IMG" \
  "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
aws s3 cp '$MIGRATION_DATABASE_S3_URI' $DB_DIR/backup.gz
echo 'Download complete'" \
  "$DB_ENV" 600

# Step 2: Restore database
echo "--- Step 2/4: Restoring database ---"
run_pod mgr-restore "$PL_IMG" \
  "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
platforma --restore-db=$DB_DIR/backup.gz --db-dir=$DB_DIR --force
echo 'Database restored'" \
  "$LIC_ENV" 1800

# Step 3: Sync primary storage (optional)
if [ -n "${MIGRATION_SOURCE_BUCKET:-}" ]; then
  echo "--- Step 3/4: Syncing primary storage ---"
  SOURCE_REGION="${MIGRATION_SOURCE_REGION:-$REGION}"

  SYNC_ENV="[]"
  if [ -n "${MIGRATION_STORAGE_ACCESS_KEY:-}" ]; then
    SYNC_ENV='[{"name":"AWS_ACCESS_KEY_ID","value":"'"$MIGRATION_STORAGE_ACCESS_KEY"'"},{"name":"AWS_SECRET_ACCESS_KEY","value":"'"$MIGRATION_STORAGE_SECRET_KEY"'"}]'
  fi

  run_pod mgr-sync "$AWS_IMG" \
    "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
aws s3 sync 's3://$MIGRATION_SOURCE_BUCKET/$MIGRATION_SOURCE_PREFIX' 's3://$S3_BUCKET/' --source-region '$SOURCE_REGION' --region '$REGION' --no-progress
echo 'Storage sync complete'" \
    "$SYNC_ENV" 86400
else
  echo "--- Step 3/4: Skipping storage sync (no source bucket configured) ---"
fi

# Step 4: Invalidate caches
echo "--- Step 4/4: Invalidating caches ---"
run_pod mgr-invalidate "$PL_IMG" \
  "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
platforma --invalidate-caches --main-root=/data/main --db-dir=$DB_DIR
date -u > $MARKER
echo 'Caches invalidated'" \
  "$LIC_ENV" 1800

# Cleanup dump file
echo "--- Cleaning up dump file ---"
run_pod mgr-cleanup "$AWS_IMG" \
  "rm -f $DB_DIR/backup.gz; echo 'Cleanup done'" \
  "[]" 120

echo "=== Platforma data migration complete ==="
