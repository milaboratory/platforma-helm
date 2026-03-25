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
#   MIGRATION_DATABASE_S3_URI   - S3 URI to database dump
#
# Optional environment variables:
#   PLATFORMA_IMAGE             - Custom platforma image
#   MIGRATION_DB_ACCESS_KEY     - AWS access key for dump bucket
#   MIGRATION_DB_SECRET_KEY     - AWS secret key for dump bucket
#   MIGRATION_SOURCE_BUCKET     - Source primary storage bucket
#   MIGRATION_SOURCE_PREFIX     - Prefix within source bucket
#   MIGRATION_SOURCE_REGION     - Source bucket region (defaults to REGION)
#   MIGRATION_STORAGE_ACCESS_KEY - AWS access key for source storage
#   MIGRATION_STORAGE_SECRET_KEY - AWS secret key for source storage
# =============================================================================
set -euo pipefail

if [ -z "${MIGRATION_DATABASE_S3_URI:-}" ]; then
  echo "MIGRATION_DATABASE_S3_URI not set, skipping migration"
  exit 0
fi

echo "=== Platforma data migration ==="

PVC="platforma-database"
DB_DIR="/data/database"
MARKER="$DB_DIR/.migration-complete"
PL_IMG="${PLATFORMA_IMAGE:-quay.io/milaboratories/platforma:${PLATFORMA_VERSION}}"
AWS_IMG="amazon/aws-cli:2.27.22"

# Helper: run a pod with database PVC, stream logs, wait, cleanup
run_pod() {
  local name="$1" image="$2" script="$3" timeout="$4"
  shift 4
  # remaining args are optional: env var pairs NAME=VALUE

  echo "  Starting pod: $name"
  kubectl delete pod/"$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null

  # Build env section
  local env_yaml="          env: []"
  if [ $# -gt 0 ]; then
    env_yaml="          env:"
    while [ $# -gt 0 ]; do
      local key="${1%%=*}"
      local val="${1#*=}"
      env_yaml="$env_yaml
            - name: $key
              value: \"$val\""
      shift
    done
  fi

  cat <<PODEOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: $PVC
  containers:
    - name: $name
      image: $image
      command: ["/bin/sh", "-ec"]
      args:
        - |
          $script
$env_yaml
      volumeMounts:
        - name: db
          mountPath: $DB_DIR
PODEOF

  kubectl wait pod/"$name" -n "$NAMESPACE" --for=condition=Ready --timeout=120s 2>/dev/null || true
  kubectl logs -f "$name" -n "$NAMESPACE" || true
  kubectl wait pod/"$name" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${timeout}s"
  kubectl delete pod/"$name" -n "$NAMESPACE"
  echo "  Pod $name completed"
}

# Helper: run a pod that needs PL_LICENSE from secret
run_pl_pod() {
  local name="$1" script="$2" timeout="$3"

  echo "  Starting pod: $name"
  kubectl delete pod/"$name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null

  cat <<PODEOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: $PVC
  containers:
    - name: $name
      image: $PL_IMG
      command: ["/bin/sh", "-ec"]
      args:
        - |
          $script
      env:
        - name: PL_LICENSE
          valueFrom:
            secretKeyRef:
              name: platforma-license
              key: MI_LICENSE
      volumeMounts:
        - name: db
          mountPath: $DB_DIR
PODEOF

  kubectl wait pod/"$name" -n "$NAMESPACE" --for=condition=Ready --timeout=120s 2>/dev/null || true
  kubectl logs -f "$name" -n "$NAMESPACE" || true
  kubectl wait pod/"$name" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${timeout}s"
  kubectl delete pod/"$name" -n "$NAMESPACE"
  echo "  Pod $name completed"
}

# Ensure namespace exists
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

# Ensure database PVC exists with Helm labels (so helm install can adopt it)
if ! kubectl get pvc "$PVC" -n "$NAMESPACE" 2>/dev/null; then
  echo "Creating database PVC..."
  cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
EOF
fi

# Step 1: Download dump
echo "--- Step 1/4: Downloading database dump ---"
DL_ARGS=""
if [ -n "${MIGRATION_DB_ACCESS_KEY:-}" ]; then
  run_pod mgr-download "$AWS_IMG" \
    "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
aws s3 cp '$MIGRATION_DATABASE_S3_URI' $DB_DIR/backup.gz
echo 'Download complete'" \
    600 \
    "AWS_ACCESS_KEY_ID=${MIGRATION_DB_ACCESS_KEY}" \
    "AWS_SECRET_ACCESS_KEY=${MIGRATION_DB_SECRET_KEY}"
else
  run_pod mgr-download "$AWS_IMG" \
    "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
aws s3 cp '$MIGRATION_DATABASE_S3_URI' $DB_DIR/backup.gz
echo 'Download complete'" \
    600
fi

# Step 2: Restore database
echo "--- Step 2/4: Restoring database ---"
run_pl_pod mgr-restore \
  "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
platforma --restore-db=$DB_DIR/backup.gz --db-dir=$DB_DIR --force
echo 'Database restored'" \
  1800

# Step 3: Sync primary storage (optional)
if [ -n "${MIGRATION_SOURCE_BUCKET:-}" ]; then
  echo "--- Step 3/4: Syncing primary storage ---"
  SOURCE_REGION="${MIGRATION_SOURCE_REGION:-$REGION}"
  SYNC_SCRIPT="if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
aws s3 sync 's3://${MIGRATION_SOURCE_BUCKET}/${MIGRATION_SOURCE_PREFIX:-}' 's3://${S3_BUCKET}/' --source-region '$SOURCE_REGION' --region '$REGION' --no-progress
echo 'Storage sync complete'"

  if [ -n "${MIGRATION_STORAGE_ACCESS_KEY:-}" ]; then
    run_pod mgr-sync "$AWS_IMG" "$SYNC_SCRIPT" 86400 \
      "AWS_ACCESS_KEY_ID=${MIGRATION_STORAGE_ACCESS_KEY}" \
      "AWS_SECRET_ACCESS_KEY=${MIGRATION_STORAGE_SECRET_KEY}"
  else
    run_pod mgr-sync "$AWS_IMG" "$SYNC_SCRIPT" 86400
  fi
else
  echo "--- Step 3/4: Skipping storage sync (no source bucket) ---"
fi

# Step 4: Invalidate caches
echo "--- Step 4/4: Invalidating caches ---"
run_pl_pod mgr-invalidate \
  "if [ -f $MARKER ]; then echo 'Already completed'; exit 0; fi
platforma --invalidate-caches --main-root=/data/main --db-dir=$DB_DIR
date -u > $MARKER
echo 'Caches invalidated'" \
  1800

# Cleanup dump file
echo "--- Cleaning up dump file ---"
run_pod mgr-cleanup "$AWS_IMG" "rm -f $DB_DIR/backup.gz; echo 'Cleanup done'" 120

echo "=== Platforma data migration complete ==="
