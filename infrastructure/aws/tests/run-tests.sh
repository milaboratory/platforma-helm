#!/usr/bin/env bash
# =============================================================================
# End-to-end test runner for Platforma AWS infrastructure
#
# Tests (without Platforma):
#   1. Kueue + AppWrapper setup
#   2. EFS StorageClass + PVC provisioning
#   3. Cluster Autoscaler scale-up (3 batch nodes via AppWrapper jobs)
#   4. EFS sequential write/read test
#   5. EFS parallel write test
#   6. ALB Controller + External DNS (nginx stub)
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - CloudFormation stack deployed with DeployPlatforma=false
#   - All required env vars set (see below)
#
# Required env vars (from CloudFormation Outputs):
#   CLUSTER_NAME     EKS cluster name
#   REGION           AWS region
#   EFS_ID           EfsFileSystemId
#   CERTIFICATE_ARN  CertificateArn
#
# Set yourself:
#   NGINX_DOMAIN     A valid subdomain under your Route53 hosted zone
#                    e.g. nginx-test.platforma.example.com
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Validate required vars ---
: "${CLUSTER_NAME:?Set CLUSTER_NAME from CloudFormation Outputs}"
: "${REGION:?Set REGION from CloudFormation Outputs}"
: "${EFS_ID:?Set EFS_ID from CloudFormation Outputs (EfsFileSystemId)}"
: "${CERTIFICATE_ARN:?Set CERTIFICATE_ARN from CloudFormation Outputs}"
: "${NGINX_DOMAIN:?Set NGINX_DOMAIN to a valid subdomain under your Route53 zone}"

echo "=== Platforma AWS Infrastructure Tests ==="
echo "Cluster: $CLUSTER_NAME  Region: $REGION"
echo "EFS: $EFS_ID"
echo "Nginx domain: $NGINX_DOMAIN"
echo ""

# --- Step 0: kubeconfig ---
echo "--- Configuring kubectl ---"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
kubectl get nodes -L node.kubernetes.io/pool
echo ""

# --- Step 1: Kueue setup ---
echo "--- Step 1: Kueue test setup ---"
kubectl apply -f "$SCRIPT_DIR/01-kueue-setup.yaml"
echo "Waiting for LocalQueue to be active..."
sleep 5
kubectl get clusterqueues,localqueues -A
echo ""

# --- Step 2: EFS StorageClass + PVC ---
echo "--- Step 2: EFS StorageClass + PVC ---"
# Substitute EFS file system ID into the manifest
sed "s/EFS_FILE_SYSTEM_ID/$EFS_ID/g" "$SCRIPT_DIR/02-efs-pvc.yaml" | kubectl apply -f -
echo "Waiting for PVC to bind (up to 60s)..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/efs-test-pvc -n platforma-test --timeout=60s
echo "PVC bound."
echo ""

# --- Step 3: Cluster Autoscaler scale-up test ---
echo "--- Step 3: Cluster Autoscaler scale-up test ---"
echo "Submitting 3 AppWrapper jobs (6 CPU / 24Gi each) — expect 3 batch nodes to start..."
kubectl apply -f "$SCRIPT_DIR/03-autoscaler-test.yaml"
echo ""
echo "Watch progress (Ctrl-C when done):"
echo "  kubectl get nodes -L node.kubernetes.io/pool -w"
echo "  kubectl get appwrappers -n platforma-test -w"
echo ""
echo "Waiting up to 5 min for all 3 AppWrappers to reach Running/Succeeded..."
for i in 1 2 3; do
  kubectl wait appwrapper/autoscaler-test-$i \
    -n platforma-test \
    --for=condition=QuotaReserved \
    --timeout=300s && echo "autoscaler-test-$i: quota reserved (node scaling triggered)"
done
echo ""
echo "Nodes after scale-up:"
kubectl get nodes -L node.kubernetes.io/pool
echo ""

# Wait for at least 1 batch node to be Ready before submitting EFS jobs.
# Nodes can take 12-13 min when a prior scale-down is still in progress.
echo "Waiting for batch nodes to be Ready (up to 10 min)..."
for i in $(seq 1 60); do
  BATCH_READY=$(kubectl get nodes -l "node.kubernetes.io/pool=batch" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | tr ' ' '\n' | grep -c "True" || echo 0)
  if [ "${BATCH_READY}" -ge 1 ]; then
    echo "  ${BATCH_READY} batch node(s) ready."
    break
  fi
  echo "  Waiting for batch nodes... ($((i * 10))s)"
  sleep 10
done
kubectl get nodes -L node.kubernetes.io/pool
echo ""

# --- Step 4: EFS sequential test ---
echo "--- Step 4: EFS sequential write/read test ---"
# Apply all EFS test AppWrappers at once; efs-read polls until efs-write's file appears
kubectl apply -f "$SCRIPT_DIR/04-efs-test.yaml"
echo "Waiting for efs-write and efs-read to complete (up to 15 min)..."
kubectl wait --for=condition=Complete job/efs-write -n platforma-test --timeout=900s
kubectl wait --for=condition=Complete job/efs-read -n platforma-test --timeout=900s
echo "Sequential test logs:"
kubectl logs -n platforma-test -l job-name=efs-write --tail=5
kubectl logs -n platforma-test -l job-name=efs-read --tail=5
echo ""

# --- Step 5: EFS parallel test ---
echo "--- Step 5: EFS parallel write test ---"
echo "Waiting for parallel verify job (up to 15 min)..."
kubectl wait --for=condition=Complete job/efs-parallel-verify -n platforma-test --timeout=900s
echo "Parallel verify logs:"
kubectl logs -n platforma-test -l job-name=efs-parallel-verify --tail=10
echo ""

# --- Step 6: Nginx stub (ALB + External DNS) ---
echo "--- Step 6: Nginx stub — ALB + External DNS ---"
export DOMAIN="$NGINX_DOMAIN"
envsubst < "$SCRIPT_DIR/05-nginx-stub.yaml" | kubectl apply --server-side -f -
echo "Waiting for Ingress to get an ALB address (up to 3 min)..."
for i in $(seq 1 18); do
  ADDR=$(kubectl get ingress nginx-stub -n platforma-test -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ADDR" ]; then
    echo "ALB address: $ADDR"
    break
  fi
  echo "  Waiting... ($((i * 10))s)"
  sleep 10
done
echo ""
echo "External DNS will write a Route53 record within ~60s."
echo "Verify DNS:"
echo "  nslookup $NGINX_DOMAIN"
echo "  curl -k https://$NGINX_DOMAIN"
echo ""

# --- Summary ---
echo "=== Test summary ==="
echo "Nodes:"
kubectl get nodes -L node.kubernetes.io/pool
echo ""
echo "AppWrappers:"
kubectl get appwrappers -n platforma-test
echo ""
echo "Jobs:"
kubectl get jobs -n platforma-test
echo ""
echo "Ingress:"
kubectl get ingress -n platforma-test
echo ""
echo "All infrastructure tests complete."
echo "To clean up test resources: kubectl delete namespace platforma-test"
echo "  (this removes all test AppWrappers, jobs, PVCs, and the nginx stub)"
echo "Note: EFS data is NOT deleted — the PV uses Retain policy."
