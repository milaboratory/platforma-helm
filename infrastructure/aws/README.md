# AWS EKS Infrastructure Setup for Platforma

Complete guide to deploy Platforma with Kueue job queueing and AppWrapper on AWS EKS.

## Quick start with CloudFormation

Deploy all AWS infrastructure with one click:

1. Launch the [CloudFormation template](cloudformation.yaml) in AWS Console
2. Fill in parameters (cluster name, instance types, optional existing VPC)
3. Optional: provide `HostedZoneId` and `DomainName` for automatic TLS certificate
4. Optional: provide `PublicSubnetIds` when using an existing VPC with ALB
5. Wait ~15-20 minutes for stack creation
6. Configure kubectl: `aws eks update-kubeconfig --name <ClusterName> --region <region>`
7. Create the [gp3 StorageClass](#create-gp3-storageclass) and [EFS StorageClass](#create-efs-storageclass) (CloudFormation cannot create K8s resources)
8. Continue from [Step 3](#step-3-install-cluster-autoscaler) below (Steps 1-2 are handled by CloudFormation)

The template creates: EKS cluster, 5 node groups (system, ui, 3 batch tiers), EFS, S3 bucket, all IAM roles (cluster, node group, CSI drivers, Platforma IRSA, optional Autoscaler/ALB Controller/External DNS IRSA). See [permissions.md](permissions.md) for full permissions reference.

For manual setup, continue with the step-by-step guide below.

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│                     EKS Cluster (1.31)                            │
│                                                                   │
│  ┌──────────┐  ┌──────────┐  ┌─────────────────────────────┐    │
│  │  System   │  │    UI    │  │        Batch Nodes          │    │
│  │  Nodes    │  │  Nodes   │  │ medium    large    xlarge   │    │
│  │ t3.large  │  │t3.xlarge │  │m5.2xl    m5.4xl   m5.8xl   │    │
│  │  2 fixed  │  │  0-4     │  │ 0-16      0-16     0-16    │    │
│  ├──────────┤  ├──────────┤  ├─────────────────────────────┤    │
│  │Platforma │  │ UI tasks │  │  light / medium / heavy      │    │
│  │ Kueue    │  │          │  │    compute jobs              │    │
│  │AppWrapper│  │          │  │                              │    │
│  └──────────┘  └──────────┘  └─────────────────────────────┘    │
│                       │               │                          │
│        Cluster Autoscaler (--expander=least-waste)               │
│        Selects smallest node group that fits each pending pod    │
│                                                                   │
│  Storage:  EBS gp3 (database)  │  EFS (shared workspace)         │
└──────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS CLI configured with appropriate permissions
- eksctl v0.170.0+
- kubectl v1.28+
- Helm v3.12+

## Files in this directory

| File | Description |
|------|-------------|
| `cloudformation.yaml` | One-click CloudFormation template (EKS + EFS + S3 + IAM) |
| `permissions.md` | AWS permissions reference for all components |
| `eksctl-cluster.yaml` | EKS cluster definition for manual setup (5 node groups, CSI drivers) |
| `kueue-values.yaml` | Kueue Helm values with AppWrapper enabled |
| `cluster-autoscaler-policy.json` | IAM policy for Cluster Autoscaler |
| `values-aws.yaml` | Platforma Helm values for AWS (filesystem primary storage) |
| `values-aws-s3.yaml` | Platforma Helm values for AWS with S3 primary storage |

---

## Step 1: Create EKS Cluster

> **CloudFormation users:** Skip to [Step 3](#step-3-install-cluster-autoscaler). The CloudFormation template creates the cluster, node groups, EFS, and S3 bucket.

```bash
eksctl create cluster -f eksctl-cluster.yaml
```

This creates:
- EKS 1.31 cluster with OIDC enabled
- **System** node group: 2x t3.large (Platforma server, Kueue, controllers)
- **UI** node group: 0-4x t3.xlarge (interactive tasks, tainted `dedicated=ui`)
- **Batch-medium** node group: 0-16x m5.2xlarge (8 vCPU, tainted `dedicated=batch`)
- **Batch-large** node group: 0-16x m5.4xlarge (16 vCPU, tainted `dedicated=batch`)
- **Batch-xlarge** node group: 0-16x m5.8xlarge (32 vCPU, tainted `dedicated=batch`)
- EBS CSI driver addon (for gp3 PVCs)
- EFS CSI driver addon (for shared workspace)
- Autoscaler autodiscovery tags on all node groups

All three batch groups share label `node.kubernetes.io/pool=batch` and taint `dedicated=batch:NoSchedule`. Cluster Autoscaler with `--expander=least-waste` selects the smallest group that fits each pending pod.

Takes ~15 minutes. Verify:

```bash
kubectl get nodes -L node.kubernetes.io/pool
```

### Create gp3 StorageClass

EKS default `gp2` uses a legacy provisioner. Create a `gp3` StorageClass:

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
```

### Create EFS StorageClass

EFS requires a StorageClass for dynamic provisioning with Access Points. Replace `$EFS_ID` with your EFS filesystem ID (from `aws efs describe-file-systems` or CloudFormation output `EfsFileSystemId`):

```bash
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-platforma
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $EFS_ID
  directoryPerms: "755"
  uid: "1010"
  gid: "1010"
  basePath: "/dynamic"
EOF
```

The `uid`/`gid` parameters enforce UID 1010 / GID 1010 ownership on EFS Access Points, matching Platforma's non-root container user.

---

## Step 2: Create EFS Filesystem

> **CloudFormation users:** Skip to [Step 3](#step-3-install-cluster-autoscaler). EFS is created by the template (you still need to create the [EFS StorageClass](#create-efs-storageclass) above).

EFS provides the RWX storage required for Platforma's shared workspace (jobs read inputs and write outputs here).

```bash
# Get VPC and CIDR
VPC_ID=$(aws eks describe-cluster --name platforma-cluster --query "cluster.resourcesVpcConfig.vpcId" --output text)
CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query "Vpcs[0].CidrBlock" --output text)

# Create security group for EFS
SG_ID=$(aws ec2 create-security-group \
  --group-name platforma-efs-sg \
  --description "Security group for Platforma EFS" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

# Allow NFS from VPC
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 2049 \
  --cidr $CIDR_BLOCK

# Create EFS filesystem
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=platforma-workspace \
  --query 'FileSystemId' --output text)

echo "EFS Filesystem ID: $EFS_ID"

# Create mount targets in each subnet
SUBNET_IDS=$(aws eks describe-cluster --name platforma-cluster \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text)

for SUBNET_ID in $SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id $EFS_ID \
    --subnet-id $SUBNET_ID \
    --security-groups $SG_ID 2>/dev/null || true
done

echo "Waiting for mount targets to become available..."
sleep 30
```

---

## Step 3: Install Cluster Autoscaler

Cluster Autoscaler scales node groups when Kueue admits jobs that can't be scheduled. Required for batch/UI node groups that start at 0 nodes.

### Expected Performance

| Operation | Duration | Notes |
|-----------|----------|-------|
| Scale-up (0 to 1 node) | ~60 seconds | Kueue admission + autoscaler detection + EC2 launch + node ready |
| Scale-down | 6-10 minutes | Configurable via cooldown settings |

### Option A: CloudFormation users

The IRSA role is already created by the template. Create the SA and tag the ASGs for autoscaler discovery:

```bash
AUTOSCALER_ROLE_ARN=<AutoscalerRoleArn from stack outputs>
CLUSTER_NAME=platforma-cluster  # Must match your ClusterName parameter

kubectl create serviceaccount cluster-autoscaler -n kube-system
kubectl annotate serviceaccount cluster-autoscaler \
  -n kube-system \
  eks.amazonaws.com/role-arn=$AUTOSCALER_ROLE_ARN

# Tag ASGs for autoscaler discovery (CF cannot set dynamic tag keys)
for NG in $(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --query 'nodegroups[]' --output text); do
  ASG=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NG \
    --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)
  aws autoscaling create-or-update-tags --tags \
    "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/$CLUSTER_NAME,Value=owned,PropagateAtLaunch=true"
done
```

### Option B: Manual setup

```bash
# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create IAM policy
# Note: cluster-autoscaler-policy.json hardcodes "platforma-cluster".
# If your cluster has a different name, update the tag condition before creating.
aws iam create-policy \
  --policy-name AmazonEKSClusterAutoscalerPolicy \
  --policy-document file://cluster-autoscaler-policy.json

# Create IRSA (IAM Role for Service Account)
eksctl create iamserviceaccount \
  --cluster=platforma-cluster \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy \
  --approve
```

### Install Cluster Autoscaler

```bash
# Install Cluster Autoscaler
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

# Change awsRegion to your region
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=platforma-cluster \
  --set awsRegion=eu-central-1 \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-unneeded-time=10m \
  --set extraArgs.scale-down-utilization-threshold=0.5 \
  --set extraArgs.expander=least-waste
```

### Configuration Options

| Setting | Production | Dev/Test | Description |
|---------|------------|----------|-------------|
| `scale-down-delay-after-add` | 10m | 2m | Wait after scale-up before considering scale-down |
| `scale-down-unneeded-time` | 10m | 2m | Time node must be unneeded before removal |
| `scale-down-utilization-threshold` | 0.5 | 0.5 | Scale down if utilization below this |
| `expander` | least-waste | least-waste | Strategy for choosing node group to scale |

Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler
```

---

## Step 4: Install AWS Load Balancer Controller

The ALB Controller provisions AWS Application/Network Load Balancers from Kubernetes Ingress resources.

### Option A: CloudFormation users

The IRSA role is already created by the template.

```bash
ALB_ROLE_ARN=<ALBControllerRoleArn from stack outputs>

kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn=$ALB_ROLE_ARN
```

### Option B: Manual setup

```bash
# Download the IAM policy (v2.11.0)
curl -o /tmp/alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

# Create IAM policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-iam-policy.json

# Create IRSA
eksctl create iamserviceaccount \
  --cluster=platforma-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

### Install the controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=platforma-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## Step 5: Install External DNS

External DNS automatically manages Route53 DNS records from Kubernetes Ingress and Service annotations.

### Option A: CloudFormation users

The IRSA role is already created by the template.

```bash
EXTERNALDNS_ROLE_ARN=<ExternalDNSRoleArn from stack outputs>

kubectl create serviceaccount external-dns -n kube-system
kubectl annotate serviceaccount external-dns \
  -n kube-system \
  eks.amazonaws.com/role-arn=$EXTERNALDNS_ROLE_ARN
```

### Option B: Manual setup

```bash
# Create IAM policy (scoped to your hosted zone)
cat > /tmp/external-dns-policy.json <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChangeRecords",
      "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets"],
      "Resource": "arn:aws:route53:::hostedzone/YOUR_HOSTED_ZONE_ID"
    },
    {
      "Sid": "ListZones",
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResource"
      ],
      "Resource": "*"
    }
  ]
}
POLICY

aws iam create-policy \
  --policy-name ExternalDNSPolicy \
  --policy-document file:///tmp/external-dns-policy.json

# Create IRSA
eksctl create iamserviceaccount \
  --cluster=platforma-cluster \
  --namespace=kube-system \
  --name=external-dns \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalDNSPolicy \
  --approve
```

### Install External DNS

```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

helm install external-dns external-dns/external-dns \
  -n kube-system \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-dns \
  --set domainFilters[0]=your-domain.com \
  --set policy=upsert-only \
  --set registry=txt \
  --set txtOwnerId=platforma-cluster
```

Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=external-dns
```

---

## Step 6: Create Platforma S3 IAM policy and IRSA

> **CloudFormation users:** The template creates the S3 bucket, IAM policy, and IRSA role. Skip to [Step 7](#step-7-install-kueue-with-appwrapper-support). You'll still need to create the namespace and annotate the service account:
> ```bash
> kubectl create namespace platforma
> kubectl create serviceaccount platforma -n platforma
> kubectl annotate serviceaccount platforma -n platforma \
>   eks.amazonaws.com/role-arn=<PlatformaRoleArn from stack outputs>
> ```

Platforma needs S3 access for primary storage. **If using filesystem primary storage (`values-aws.yaml`), skip this step entirely** and go to [Step 7](#step-7-install-kueue-with-appwrapper-support).

Create a least-privilege IAM policy scoped to the bucket, then bind it to the Platforma Kubernetes service account via IRSA.

### IAM permissions required

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `s3:ListBucket` | Bucket ARN | List objects |
| `s3:ListBucketMultipartUploads` | Bucket ARN | List in-progress uploads |
| `s3:GetObject` | Bucket ARN/* | Read objects |
| `s3:PutObject` | Bucket ARN/* | Write objects |
| `s3:DeleteObject` | Bucket ARN/* | Delete objects |
| `s3:GetObjectAttributes` | Bucket ARN/* | Get object metadata |
| `s3:AbortMultipartUpload` | Bucket ARN/* | Clean up failed uploads |
| `s3:ListMultipartUploadParts` | Bucket ARN/* | List upload parts |

### Create S3 bucket and IRSA

```bash
# Create S3 bucket
aws s3api create-bucket \
  --bucket platforma-storage-${AWS_ACCOUNT_ID} \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

# Create IAM policy (use the template in this directory or inline)
cat > /tmp/platforma-s3-policy.json <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::platforma-storage-ACCOUNT_ID"
    },
    {
      "Sid": "ReadWriteObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:GetObjectAttributes",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::platforma-storage-ACCOUNT_ID/*"
    }
  ]
}
POLICY
# Replace ACCOUNT_ID with your actual account ID
# macOS: sed -i '' | Linux: sed -i
sed "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" /tmp/platforma-s3-policy.json > /tmp/platforma-s3-policy-final.json
mv /tmp/platforma-s3-policy-final.json /tmp/platforma-s3-policy.json

S3_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/platforma-s3-access"
aws iam create-policy \
  --policy-name platforma-s3-access \
  --policy-document file:///tmp/platforma-s3-policy.json

# Create IRSA — binds K8s SA to IAM role via OIDC
eksctl create iamserviceaccount \
  --cluster=platforma-cluster \
  --namespace=platforma \
  --name=platforma \
  --attach-policy-arn=$S3_POLICY_ARN \
  --approve
```

The `eksctl create iamserviceaccount` command creates a K8s service account annotated with `eks.amazonaws.com/role-arn`. The Helm chart must use this pre-created SA:

```yaml
serviceAccount:
  create: false
  name: platforma
```

Verify IRSA is working:

```bash
kubectl describe sa platforma -n platforma | grep eks.amazonaws.com/role-arn
```

---

## Step 7: Install Kueue with AppWrapper support

Kueue manages job queuing and resource allocation. AppWrapper provides single-resource status monitoring with automatic retries.

### Install Kueue

```bash
helm install kueue oci://registry.k8s.io/kueue/charts/kueue \
  --version 0.16.1 \
  -n kueue-system --create-namespace \
  -f kueue-values.yaml
```

Wait for readiness:

```bash
kubectl wait --for=condition=Available deployment/kueue-controller-manager \
  -n kueue-system --timeout=120s
```

### Install AppWrapper CRD and Controller

AppWrapper is a **separate component** from Kueue. It has its own controller and CRD.

```bash
kubectl apply --server-side -f https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml

kubectl wait --for=condition=Available deployment/appwrapper-controller-manager \
  -n appwrapper-system --timeout=120s
```

Verify:

```bash
kubectl get pods -n kueue-system
kubectl get pods -n appwrapper-system
kubectl get crd appwrappers.workload.codeflare.dev
```

---

## Step 8: Create license secret

```bash
# Namespace was created in Step 6. If you skipped Step 6 (CloudFormation handles S3 IRSA):
kubectl create namespace platforma 2>/dev/null || true

kubectl create secret generic platforma-license \
  -n platforma \
  --from-literal=MI_LICENSE="your-license-key"
```

---

## Step 9: Install Platforma

### With filesystem primary storage (default)

Requires the `efs-platforma` StorageClass created in [Create EFS StorageClass](#create-efs-storageclass).

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 \
  -n platforma \
  -f values-aws.yaml
```

### With S3 primary storage (CloudFormation users)

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version 3.0.0 \
  -n platforma \
  -f values-aws-s3.yaml \
  --set storage.main.s3.bucket=<S3BucketName from stack outputs> \
  --set storage.main.s3.region=<Region from stack outputs> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=platforma
```

Verify:

```bash
kubectl get pods -n platforma
kubectl get pvc -n platforma
kubectl get clusterqueues
kubectl get localqueues -n platforma
```

---

## Step 10: Configure ingress (optional)

The Desktop App connects to Platforma via gRPC. For production access, expose the gRPC port through an ingress or load balancer.

### Option A: AWS ALB Ingress

Requires the ALB Controller installed in [Step 4](#step-4-install-aws-load-balancer-controller).

Add to your values file or pass via `--set`:

```yaml
ingress:
  enabled: true
  className: alb
  api:
    host: platforma.example.com
    tls:
      enabled: true
      secretName: ""  # ALB terminates TLS via ACM, no K8s secret needed
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:REGION:ACCOUNT:certificate/CERT_ID
      alb.ingress.kubernetes.io/backend-protocol-version: GRPC
  # data: only needed when storage.main.type=fs
  # data:
  #   host: platforma-data.example.com
  #   annotations:
  #     alb.ingress.kubernetes.io/scheme: internet-facing
  #     alb.ingress.kubernetes.io/target-type: ip
  #     alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
  #     alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:REGION:ACCOUNT:certificate/CERT_ID
```

### Option B: NLB LoadBalancer

Simpler alternative — exposes ports directly without ingress:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```

### Option C: Port-forwarding (development)

```bash
kubectl port-forward svc/platforma -n platforma 6345:6345
# Desktop App → localhost:6345
```

---

## Verification checklist

Run this to verify the complete installation:

```bash
echo "=== Cluster Nodes ==="
kubectl get nodes -L node.kubernetes.io/pool

echo ""
echo "=== Cluster Autoscaler ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler

echo ""
echo "=== Kueue ==="
kubectl get pods -n kueue-system

echo ""
echo "=== AppWrapper Controller ==="
kubectl get pods -n appwrapper-system

echo ""
echo "=== AppWrapper CRD ==="
kubectl get crd appwrappers.workload.codeflare.dev

echo ""
echo "=== Kueue Resources ==="
kubectl get resourceflavors,clusterqueues,localqueues --all-namespaces

echo ""
echo "=== Platforma ==="
kubectl get pods -n platforma
kubectl get pvc -n platforma
```

Expected:
- 2+ system nodes, 0 batch nodes (scales on demand)
- Cluster Autoscaler pod running in kube-system
- Kueue controller pod running in kueue-system
- AppWrapper controller pod running in appwrapper-system
- AppWrapper CRD exists
- ResourceFlavors, ClusterQueues, LocalQueues created
- Platforma pod running with PVCs bound

---

## How It Works

1. Platforma creates a Job (wrapped in AppWrapper) and assigns it to a Kueue LocalQueue
2. Kueue evaluates quota in the corresponding ClusterQueue
3. If quota is available, Kueue admits the workload and the Pod is created (Pending)
4. Cluster Autoscaler detects unschedulable pod (~10s scan cycle)
5. Autoscaler triggers scale-up of the appropriate node group (respects taints/labels)
6. EC2 instance launches and joins cluster (~60s total)
7. Pod is scheduled and runs
8. AppWrapper monitors pod health and reports status via `status.phase`
9. On failure, AppWrapper retries automatically (up to `retryLimit`)
10. When node is idle for `scale-down-unneeded-time`, Autoscaler removes it

---

## Troubleshooting

### Pods stuck in Pending

```bash
# Check if Kueue admitted the workload
kubectl get workloads -A

# Check Cluster Autoscaler logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50

# Check node group scaling activity
aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg-name> --max-items 5
```

### PVC stuck in Pending

```bash
# Verify gp3 StorageClass exists
kubectl get sc gp3

# Verify EBS CSI driver is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

### EFS mount failures

```bash
# Verify mount targets exist
aws efs describe-mount-targets --file-system-id $EFS_ID

# Verify EFS CSI driver is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver

# Check security group allows NFS (port 2049)
aws ec2 describe-security-groups --group-ids $SG_ID
```

### AppWrapper not transitioning to Failed

```bash
# Check AppWrapper status
kubectl get appwrapper <name> -o yaml

# Check controller logs
kubectl logs -n appwrapper-system -l control-plane=controller-manager --tail=50
```

---

## Cleanup

### CloudFormation deployment

```bash
# Delete Helm releases first
helm uninstall platforma -n platforma
helm uninstall external-dns -n kube-system
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall kueue -n kueue-system
helm uninstall cluster-autoscaler -n kube-system
kubectl delete -f https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml

# Empty S3 bucket (required before stack deletion)
aws s3 rm s3://<S3BucketName> --recursive

# Delete CloudFormation stack (removes EKS, EFS, all IAM roles)
# Note: S3 bucket has DeletionPolicy: Retain — delete manually after stack removal:
#   aws s3 rb s3://<S3BucketName> --force
aws cloudformation delete-stack --stack-name platforma-stack
aws cloudformation wait stack-delete-complete --stack-name platforma-stack
```

### Manual (eksctl) deployment

```bash
# Delete Helm releases
helm uninstall platforma -n platforma
helm uninstall external-dns -n kube-system
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall kueue -n kueue-system
helm uninstall cluster-autoscaler -n kube-system
kubectl delete -f https://github.com/project-codeflare/appwrapper/releases/download/v1.1.2/install.yaml

# Delete EFS
for MT_ID in $(aws efs describe-mount-targets --file-system-id $EFS_ID --query 'MountTargets[*].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $MT_ID
done
sleep 60
aws efs delete-file-system --file-system-id $EFS_ID
aws ec2 delete-security-group --group-id $SG_ID

# Delete S3 bucket (if created)
# aws s3 rb s3://platforma-storage-${AWS_ACCOUNT_ID} --force

# Delete IAM resources
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
eksctl delete iamserviceaccount --cluster=platforma-cluster --namespace=kube-system --name=cluster-autoscaler
eksctl delete iamserviceaccount --cluster=platforma-cluster --namespace=kube-system --name=aws-load-balancer-controller
eksctl delete iamserviceaccount --cluster=platforma-cluster --namespace=kube-system --name=external-dns
eksctl delete iamserviceaccount --cluster=platforma-cluster --namespace=platforma --name=platforma
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ExternalDNSPolicy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/platforma-s3-access

# Delete cluster
eksctl delete cluster --name platforma-cluster
```
