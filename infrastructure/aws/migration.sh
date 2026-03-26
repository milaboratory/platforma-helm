#!/usr/bin/env bash
# =============================================================================
# Platforma data migration script
# =============================================================================
# Usage:
#   migration.sh pre-helm    — download dump, restore DB, sync storage
#   migration.sh post-helm   — invalidate caches, write marker, restart
#   migration.sh             — run both phases (for standalone use)
# =============================================================================
set -euo pipefail

if [ -z "${MIGRATION_DATABASE_S3_URI:-}" ]; then
  echo "MIGRATION_DATABASE_S3_URI not set, skipping migration"
  exit 0
fi

if [ -z "${PLATFORMA_IMAGE:-}" ] && [ -z "${PLATFORMA_VERSION:-}" ]; then
  echo "ERROR: PLATFORMA_IMAGE or PLATFORMA_VERSION must be set"
  exit 1
fi

PHASE="${1:-all}"
PVC="platforma-database"
DB_DIR="/data/database"
MARKER="$DB_DIR/.migration-complete"
PL_IMG="${PLATFORMA_IMAGE:-quay.io/milaboratories/platforma:${PLATFORMA_VERSION}}"
AWS_IMG="amazon/aws-cli:2.27.22"

# Helper: wait for pod completion, stream logs, cleanup
wait_pod() {
  local name="$1" timeout="$2"
  kubectl wait pod/"$name" -n "$NAMESPACE" --for=condition=Ready --timeout=120s 2>/dev/null || true
  kubectl logs -f "$name" -n "$NAMESPACE" || true
  kubectl wait pod/"$name" -n "$NAMESPACE" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${timeout}s"
  kubectl delete pod/"$name" -n "$NAMESPACE" --ignore-not-found
  echo "  Pod $name completed"
}

# Helper: generate pod YAML (aws-cli image, optional env vars)
make_pod() {
  local name="$1" image="$2" script="$3"
  shift 3

  local indented_script
  indented_script=$(echo "$script" | sed 's/^/          /')

  local env_section=""
  if [ $# -gt 0 ]; then
    env_section="      env:"
    while [ $# -ge 2 ]; do
      env_section="${env_section}
        - name: ${1}
          value: \"${2}\""
      shift 2
    done
  fi

  cat <<ENDPOD
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: ${PVC}
  containers:
    - name: ${name}
      image: ${image}
      command: ["/bin/sh", "-ec"]
      args:
        - |
${indented_script}
${env_section}
      volumeMounts:
        - name: db
          mountPath: ${DB_DIR}
ENDPOD
}

# Helper: generate pod YAML (platforma image, license secret, +main emptyDir)
make_pl_pod() {
  local name="$1" script="$2"

  local indented_script
  indented_script=$(echo "$script" | sed 's/^/          /')

  cat <<ENDPOD
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
spec:
  securityContext:
    fsGroup: 1010
    runAsUser: 1010
    runAsGroup: 1010
  restartPolicy: Never
  volumes:
    - name: db
      persistentVolumeClaim:
        claimName: ${PVC}
    - name: main
      emptyDir: {}
  containers:
    - name: ${name}
      image: ${PL_IMG}
      command: ["/bin/sh", "-ec"]
      args:
        - |
${indented_script}
      env:
        - name: PL_LICENSE
          valueFrom:
            secretKeyRef:
              name: platforma-license
              key: MI_LICENSE
      volumeMounts:
        - name: db
          mountPath: ${DB_DIR}
        - name: main
          mountPath: /data/main
ENDPOD
}

# =========================================================================
# Phase: pre-helm (download, restore, sync, cleanup dump)
# =========================================================================
run_pre_helm() {
  echo "=== Platforma data migration (pre-helm) ==="

  SKIP="if [ -f ${MARKER} ]; then echo Already completed; exit 0; fi"

  # Ensure namespace exists
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true

  # Ensure gp3 storage class exists
  if ! kubectl get sc gp3 2>/dev/null; then
    echo "Creating gp3 storage class..."
    kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: ${NAMESPACE}
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
  fi

  # Ensure database PVC exists with Helm labels
  if ! kubectl get pvc "$PVC" -n "$NAMESPACE" 2>/dev/null; then
    echo "Creating database PVC..."
    kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: platforma
    meta.helm.sh/release-namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3
  resources:
    requests:
      storage: 50Gi
EOF
  else
    kubectl label pvc "$PVC" -n "$NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
    kubectl annotate pvc "$PVC" -n "$NAMESPACE" meta.helm.sh/release-name=platforma meta.helm.sh/release-namespace="$NAMESPACE" --overwrite 2>/dev/null || true
  fi

  # Step 1: Download database dump
  echo "--- Step 1/3: Downloading database dump ---"
  DL_SCRIPT="${SKIP}
aws s3 cp ${MIGRATION_DATABASE_S3_URI} ${DB_DIR}/backup.gz
echo Download complete"

  kubectl delete pod/mgr-download -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  if [ -n "${MIGRATION_DB_ACCESS_KEY:-}" ]; then
    make_pod mgr-download "$AWS_IMG" "$DL_SCRIPT" \
      AWS_ACCESS_KEY_ID "$MIGRATION_DB_ACCESS_KEY" \
      AWS_SECRET_ACCESS_KEY "$MIGRATION_DB_SECRET_KEY" \
      | kubectl apply -n "$NAMESPACE" -f -
  else
    make_pod mgr-download "$AWS_IMG" "$DL_SCRIPT" | kubectl apply -n "$NAMESPACE" -f -
  fi
  wait_pod mgr-download 600

  # Step 2: Restore database
  echo "--- Step 2/3: Restoring database ---"
  RS_SCRIPT="${SKIP}
/app/platforma --restore-db=${DB_DIR}/backup.gz --db-dir=${DB_DIR} --force
echo Database restored"

  kubectl delete pod/mgr-restore -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  make_pl_pod mgr-restore "$RS_SCRIPT" | kubectl apply -n "$NAMESPACE" -f -
  wait_pod mgr-restore 1800

  # Step 3: Sync primary storage
  if [ -n "${MIGRATION_SOURCE_BUCKET:-}" ]; then
    echo "--- Step 3/3: Syncing primary storage ---"
    SR="${MIGRATION_SOURCE_REGION:-$REGION}"
    SYNC_SCRIPT="${SKIP}
aws s3 sync s3://${MIGRATION_SOURCE_BUCKET}/${MIGRATION_SOURCE_PREFIX:-} s3://${S3_BUCKET}/ --source-region ${SR} --region ${REGION} --no-progress --copy-props none
echo Storage sync complete"

    kubectl delete pod/mgr-sync -n "$NAMESPACE" --ignore-not-found 2>/dev/null
    if [ -n "${MIGRATION_STORAGE_ACCESS_KEY:-}" ]; then
      make_pod mgr-sync "$AWS_IMG" "$SYNC_SCRIPT" \
        AWS_ACCESS_KEY_ID "$MIGRATION_STORAGE_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY "$MIGRATION_STORAGE_SECRET_KEY" \
        | kubectl apply -n "$NAMESPACE" -f -
    else
      make_pod mgr-sync "$AWS_IMG" "$SYNC_SCRIPT" | kubectl apply -n "$NAMESPACE" -f -
    fi
    wait_pod mgr-sync 86400
  else
    echo "--- Step 3/3: Skipping storage sync (no source bucket) ---"
  fi

  # Cleanup dump file
  echo "--- Cleaning up dump file ---"
  kubectl delete pod/mgr-cleanup -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  make_pod mgr-cleanup "$AWS_IMG" "rm -f ${DB_DIR}/backup.gz; echo Cleanup done" | kubectl apply -n "$NAMESPACE" -f -
  wait_pod mgr-cleanup 120

  echo "=== Pre-helm migration complete ==="
}

# =========================================================================
# Phase: post-helm (invalidate caches after Platforma applies migrations)
# =========================================================================
run_post_helm() {
  echo "=== Platforma cache invalidation (post-helm) ==="

  SKIP="if [ -f ${MARKER} ]; then echo Already completed; exit 0; fi"

  # Wait for Platforma to be ready (migrations applied)
  echo "--- Waiting for Platforma to be ready ---"
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=platforma -n "$NAMESPACE" --timeout=300s

  # Scale down Platforma to release database PVC (RWO)
  echo "--- Scaling down Platforma for cache invalidation ---"
  kubectl scale deployment/platforma -n "$NAMESPACE" --replicas=0
  kubectl wait --for=delete pod -l app.kubernetes.io/name=platforma -n "$NAMESPACE" --timeout=120s 2>/dev/null || true

  # Invalidate caches
  echo "--- Invalidating caches ---"
  IC_SCRIPT="${SKIP}
/app/platforma --invalidate-caches --main-root=/data/main --db-dir=${DB_DIR}
date -u > ${MARKER}
echo Caches invalidated"

  kubectl delete pod/mgr-invalidate -n "$NAMESPACE" --ignore-not-found 2>/dev/null
  make_pl_pod mgr-invalidate "$IC_SCRIPT" | kubectl apply -n "$NAMESPACE" -f -
  wait_pod mgr-invalidate 1800

  # Scale Platforma back up
  echo "--- Starting Platforma ---"
  kubectl scale deployment/platforma -n "$NAMESPACE" --replicas=1
  kubectl rollout status deployment/platforma -n "$NAMESPACE" --timeout=300s

  echo "=== Migration fully complete ==="
}

# =========================================================================
# Main
# =========================================================================
case "$PHASE" in
  pre-helm)
    run_pre_helm
    ;;
  post-helm)
    run_post_helm
    ;;
  all)
    run_pre_helm
    echo ""
    echo "WARNING: 'all' mode requires Platforma to be running between phases."
    echo "Use 'pre-helm' and 'post-helm' separately in CF deployments."
    echo ""
    run_post_helm
    ;;
  *)
    echo "Usage: $0 [pre-helm|post-helm|all]"
    exit 1
    ;;
esac
