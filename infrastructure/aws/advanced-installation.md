# Advanced installation (manual CLI)

Manual setup using `eksctl` and AWS CLI. Use this guide if you need full control over every resource, have custom VPC requirements, or want to manage Cluster Autoscaler, ALB Controller, and External DNS yourself — in your own namespace, with your own IAM policies and lifecycle.

For the recommended CloudFormation setup (all infrastructure and controllers managed as a single stack, controllers bundled as Helm sub-charts), see the [main guide](README.md).

## Prerequisites

- AWS CLI configured with deployer permissions (see [permissions.md](permissions.md))
- eksctl v0.170.0+
- kubectl v1.28+
- Helm v3.12+
- Python 3 (used in Step 7 for ACM certificate validation record extraction)
- A Route53 hosted zone with a registered domain

### AWS On-Demand vCPU quota

The node groups can scale up to 32 nodes per batch group. At full capacity the cluster needs ~400 On-Demand Standard vCPU (m5/r5 instances). The AWS default quota for a fresh account is 32 vCPU — request an increase before deploying.

Check your current quota:

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region $AWS_REGION \
  --query 'Quota.Value' --output text
```

If the value is below your target capacity, open a quota increase request:
[Service Quotas console → EC2 → Running On-Demand Standard instances](https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A)

Recommended minimums by workload size:

| Workload | vCPU needed | Approx. concurrent jobs |
|----------|-------------|-------------------------|
| Small team / testing | 200 | 4 large or 16 small |
| Mid-sized group | 400 | 8 large or 32 small |
| Large group | 800 | 16 large or 64 small |

Quota increases are typically approved within minutes to a few hours.

## Configuration

Set these variables before running any commands. Every step references them.

```bash
# --- Required: edit these ---
export CLUSTER_NAME="platforma-cluster"
export AWS_REGION="eu-central-1"
export DOMAIN_NAME="platforma.example.com"     # Domain for TLS/gRPC endpoint
export HOSTED_ZONE_ID="Z0123456789ABCDEF"      # Route53 hosted zone ID
export MI_LICENSE="your-license-key"            # Platforma license key

# --- Optional: defaults work for most setups ---
export PLATFORMA_NAMESPACE="platforma"
export PLATFORMA_VERSION="3.0.0"
export S3_BUCKET="platforma-storage-$(aws sts get-caller-identity --query Account --output text)-${AWS_REGION}"

# --- Derived: do not edit ---
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DOMAIN_FILTER=$(aws route53 get-hosted-zone --id $HOSTED_ZONE_ID \
  --query 'HostedZone.Name' --output text | sed 's/\.$//')
```

Verify your configuration:

```bash
echo "Cluster:    $CLUSTER_NAME"
echo "Region:     $AWS_REGION"
echo "Domain:     $DOMAIN_NAME"
echo "Zone ID:    $HOSTED_ZONE_ID"
echo "Account:    $AWS_ACCOUNT_ID"
echo "S3 bucket:  $S3_BUCKET"
echo "Zone root:  $DOMAIN_FILTER"
```

## Files reference

| File | Description |
|------|-------------|
| `eksctl-cluster.yaml` | EKS cluster template (7 node groups, CSI drivers). Uses `platforma-cluster` / `eu-central-1` as defaults. |
| `kueue-values.yaml` | Kueue Helm values with AppWrapper enabled |
| `values-aws-s3.yaml` | Platforma Helm values for AWS with S3 primary storage |

---

## Step 1: Create EKS cluster

Create the cluster from the eksctl template, substituting your cluster name and region:

```bash
sed "s/platforma-cluster/${CLUSTER_NAME}/g; s/eu-central-1/${AWS_REGION}/g" \
  eksctl-cluster.yaml | eksctl create cluster -f -
```

This creates:
- EKS 1.34 cluster with OIDC enabled
- **System** node group: 2x m5.2xlarge (8 vCPU / 32 GiB — Platforma server, Kueue, controllers)
- **UI** node group: 0-16x t3.xlarge (interactive tasks, tainted `dedicated=ui`)
- **Batch-medium** node group: 0-32x m5.2xlarge (8 vCPU / 32 GiB, tainted `dedicated=batch`)
- **Batch-large** node group: 0-32x m5.4xlarge (16 vCPU / 64 GiB, tainted `dedicated=batch`)
- **Batch-xlarge** node group: 0-32x m5.8xlarge (32 vCPU / 128 GiB, tainted `dedicated=batch`)
- **Batch-2xlarge** node group: 0-32x r5.4xlarge (16 vCPU / 128 GiB, tainted `dedicated=batch`)
- **Batch-4xlarge** node group: 0-32x r5.8xlarge (32 vCPU / 256 GiB, tainted `dedicated=batch`)
- EBS CSI driver addon (for gp3 PVCs)
- EFS CSI driver addon (for shared workspace)
- Autoscaler autodiscovery tags on all node groups

All five batch groups share label `node.kubernetes.io/pool=batch` and taint `dedicated=batch:NoSchedule`. Cluster Autoscaler with `--expander=least-waste` selects the smallest group that fits each pending pod. The r5 groups (2xlarge, 4xlarge) provide higher memory-to-CPU ratio for memory-intensive bioinformatics workloads.

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

---

## Step 2: Create EFS filesystem and StorageClass

EFS provides the RWX storage required for Platforma's shared workspace (jobs read inputs and write outputs here).

```bash
# Get VPC and CIDR from the cluster
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)
CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID \
  --query "Vpcs[0].CidrBlock" --output text)

# Create security group for EFS
SG_ID=$(aws ec2 create-security-group \
  --group-name ${CLUSTER_NAME}-efs-sg \
  --description "EFS security group for ${CLUSTER_NAME}" \
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
  --throughput-mode elastic \
  --encrypted \
  --tags Key=Name,Value=${CLUSTER_NAME}-workspace \
  --query 'FileSystemId' --output text)

echo "EFS Filesystem ID: $EFS_ID"

# Create mount targets in each private subnet
SUBNET_IDS=$(aws eks describe-cluster --name $CLUSTER_NAME \
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

### Create EFS StorageClass

EFS requires a StorageClass with Access Points for dynamic provisioning. The `uid`/`gid` parameters enforce UID 1010 / GID 1010 ownership, matching Platforma's non-root container user.

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

---

## Step 3: Install Cluster Autoscaler

Create an IAM policy scoped to ASGs tagged with the cluster name, then bind it to a Kubernetes service account via IRSA.

```bash
# Generate policy with cluster name in the tag condition
cat > /tmp/cluster-autoscaler-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": ["*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": ["*"],
      "Condition": {
        "StringEquals": {
          "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"
        }
      }
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ${CLUSTER_NAME}-autoscaler-policy \
  --policy-document file:///tmp/cluster-autoscaler-policy.json

# Create IRSA (IAM Role for Service Account)
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-autoscaler-policy \
  --approve
```

### Install via Helm

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set awsRegion=$AWS_REGION \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set extraArgs.scale-down-delay-after-add=10m \
  --set extraArgs.scale-down-unneeded-time=10m \
  --set extraArgs.scale-down-utilization-threshold=0.5 \
  --set extraArgs.expander=least-waste
```

### Configuration options

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

The ALB Controller provisions Application Load Balancers for Kubernetes Ingress resources.

```bash
# Download the IAM policy (v2.11.0)
curl -so /tmp/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name ${CLUSTER_NAME}-alb-controller-policy \
  --policy-document file:///tmp/alb-iam-policy.json

# Create IRSA
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-alb-controller-policy \
  --approve
```

### Install via Helm

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## Step 5: Install External DNS

External DNS creates Route53 records for Kubernetes Ingress resources automatically.

```bash
# Create IAM policy scoped to your hosted zone
cat > /tmp/external-dns-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChangeRecords",
      "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets"],
      "Resource": "arn:aws:route53:::hostedzone/${HOSTED_ZONE_ID}"
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
EOF

aws iam create-policy \
  --policy-name ${CLUSTER_NAME}-external-dns-policy \
  --policy-document file:///tmp/external-dns-policy.json

# Create IRSA
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=external-dns \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-external-dns-policy \
  --approve
```

### Install via Helm

```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

helm install external-dns external-dns/external-dns \
  -n kube-system \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-dns \
  --set domainFilters[0]=$DOMAIN_FILTER \
  --set policy=upsert-only \
  --set registry=txt \
  --set txtOwnerId=$CLUSTER_NAME
```

Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=external-dns
```

---

## Step 6: Create S3 bucket and IRSA roles

Platforma uses S3 for primary storage. Two service accounts need S3 access: `platforma` (server) and `platforma-jobs` (compute jobs). The Helm chart creates the K8s service accounts — you only need to create the IAM roles and pass their ARNs via `--set` in Step 10.

```bash
# Create S3 bucket
aws s3api create-bucket \
  --bucket $S3_BUCKET \
  --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION

# Block public access
aws s3api put-public-access-block \
  --bucket $S3_BUCKET \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket $S3_BUCKET \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create IAM policy (shared by both service accounts)
cat > /tmp/platforma-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}"
    },
    {
      "Sid": "ReadWriteObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:GetObjectAttributes",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ${CLUSTER_NAME}-platforma-s3-access \
  --policy-document file:///tmp/platforma-s3-policy.json

# Create namespace
kubectl create namespace $PLATFORMA_NAMESPACE 2>/dev/null || true

# Get OIDC issuer for trust policies
OIDC_ISSUER=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"

# Create IRSA role for Platforma server (SA name: platforma — created by the Helm chart)
cat > /tmp/platforma-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:sub": "system:serviceaccount:${PLATFORMA_NAMESPACE}:platforma",
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

PLATFORMA_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-platforma-irsa \
  --assume-role-policy-document file:///tmp/platforma-trust.json \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name ${CLUSTER_NAME}-platforma-irsa \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-platforma-s3-access

# Create IRSA role for Platforma jobs (SA name: platforma-jobs — created by the Helm chart)
cat > /tmp/platforma-jobs-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "${OIDC_PROVIDER_ARN}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ISSUER}:sub": "system:serviceaccount:${PLATFORMA_NAMESPACE}:platforma-jobs",
        "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

PLATFORMA_JOBS_ROLE_ARN=$(aws iam create-role \
  --role-name ${CLUSTER_NAME}-platforma-jobs-irsa \
  --assume-role-policy-document file:///tmp/platforma-jobs-trust.json \
  --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name ${CLUSTER_NAME}-platforma-jobs-irsa \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-platforma-s3-access

echo "Platforma role ARN:      $PLATFORMA_ROLE_ARN"
echo "Platforma jobs role ARN: $PLATFORMA_JOBS_ROLE_ARN"
```

---

## Step 7: Request ACM certificate

Request a TLS certificate for your domain. The Desktop App requires TLS to connect.

```bash
CERT_ARN=$(aws acm request-certificate \
  --domain-name $DOMAIN_NAME \
  --validation-method DNS \
  --region $AWS_REGION \
  --query 'CertificateArn' --output text)

echo "Certificate ARN: $CERT_ARN"

# Wait for ACM to generate the validation record
sleep 5

# Get validation record details
VALIDATION=$(aws acm describe-certificate --certificate-arn $CERT_ARN \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)

VALIDATION_NAME=$(echo $VALIDATION | python3 -c "import sys,json; print(json.load(sys.stdin)['Name'])")
VALIDATION_VALUE=$(echo $VALIDATION | python3 -c "import sys,json; print(json.load(sys.stdin)['Value'])")

echo "Creating DNS validation record: $VALIDATION_NAME -> $VALIDATION_VALUE"

# Create the CNAME record in Route53
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${VALIDATION_NAME}\",
        \"Type\": \"CNAME\",
        \"TTL\": 300,
        \"ResourceRecords\": [{\"Value\": \"${VALIDATION_VALUE}\"}]
      }
    }]
  }"

# Wait for validation (typically 2-5 minutes)
echo "Waiting for certificate validation..."
aws acm wait certificate-validated --certificate-arn $CERT_ARN
echo "Certificate validated: $CERT_ARN"
```

---

## Step 8: Install Kueue with AppWrapper support

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

### Install AppWrapper CRD and controller

AppWrapper is a separate component from Kueue with its own controller and CRD.

```bash
kubectl apply --server-side -f https://github.com/project-codeflare/appwrapper/releases/download/v1.2.0/install.yaml

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

## Step 9: Create license secret

```bash
kubectl create secret generic platforma-license \
  -n $PLATFORMA_NAMESPACE \
  --from-literal=MI_LICENSE="$MI_LICENSE"
```

---

## Step 10: Install Platforma

The `values-aws-s3.yaml` file provides the base configuration. The chart creates `platforma` and `platforma-jobs` service accounts — pass IRSA role ARNs from Step 6, EFS ID from Step 2, S3 bucket from Step 6, and cert ARN from Step 7.

Authentication: the simplest option is inline credentials. The chart auto-generates a bcrypt-hashed htpasswd secret from the username/password pairs. Alternatively, create a K8s secret yourself and set `auth.htpasswd.secretName`, or use LDAP.

```bash
helm install platforma oci://ghcr.io/milaboratory/platforma-helm/platforma \
  --version $PLATFORMA_VERSION \
  -n $PLATFORMA_NAMESPACE \
  -f values-aws-s3.yaml \
  --set storage.workspace.efs.fileSystemId=$EFS_ID \
  --set storage.main.s3.bucket=$S3_BUCKET \
  --set storage.main.s3.region=$AWS_REGION \
  --set auth.htpasswd.credentials[0].username=admin \
  --set auth.htpasswd.credentials[0].password=changeme \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$PLATFORMA_ROLE_ARN" \
  --set "jobServiceAccount.annotations.eks\.amazonaws\.com/role-arn=$PLATFORMA_JOBS_ROLE_ARN" \
  --set ingress.enabled=true \
  --set ingress.className=alb \
  --set ingress.host=$DOMAIN_NAME \
  --set ingress.tls.enabled=true \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"=internet-facing \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"=ip \
  --set-json 'ingress.annotations."alb\.ingress\.kubernetes\.io/listen-ports"=[{"HTTPS":443}]' \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/certificate-arn"=$CERT_ARN \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/backend-protocol-version"=GRPC
```

Verify:

```bash
kubectl get pods -n $PLATFORMA_NAMESPACE
kubectl get pvc -n $PLATFORMA_NAMESPACE
kubectl get ingress -n $PLATFORMA_NAMESPACE
kubectl get clusterqueues
kubectl get localqueues -n $PLATFORMA_NAMESPACE
```

---

## Step 11: Connect from Desktop App

1. Download the **Platforma Desktop App** from [platforma.bio](https://platforma.bio)
2. Open the app and add a new connection
3. Enter your gRPC endpoint: `<your DOMAIN_NAME>:443`
4. TLS via the ACM certificate secures the connection

For quick testing before DNS propagates, use port-forwarding:

```bash
kubectl port-forward svc/platforma -n $PLATFORMA_NAMESPACE 6345:6345
# Desktop App → localhost:6345
```

---

## Verification checklist

```bash
echo "=== Cluster Nodes ==="
kubectl get nodes -L node.kubernetes.io/pool

echo ""
echo "=== Cluster Autoscaler ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler

echo ""
echo "=== ALB Controller ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

echo ""
echo "=== External DNS ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=external-dns

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
kubectl get pods -n $PLATFORMA_NAMESPACE
kubectl get pvc -n $PLATFORMA_NAMESPACE
kubectl get ingress -n $PLATFORMA_NAMESPACE
```

---

## Cleanup

If running cleanup in a new shell session, set the Configuration variables from the top of this guide, then recover session-specific variables:

```bash
EFS_ID=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${CLUSTER_NAME}-workspace']].FileSystemId" --output text)
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${CLUSTER_NAME}-efs-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
CERT_ARN=$(aws acm list-certificates \
  --query "CertificateSummaryList[?DomainName=='${DOMAIN_NAME}'].CertificateArn" --output text)
```

```bash
# Delete Helm releases
helm uninstall platforma -n $PLATFORMA_NAMESPACE
helm uninstall external-dns -n kube-system
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall kueue -n kueue-system
helm uninstall cluster-autoscaler -n kube-system
kubectl delete -f https://github.com/project-codeflare/appwrapper/releases/download/v1.2.0/install.yaml

# Delete EFS (uses $EFS_ID and $SG_ID from Step 2)
for MT_ID in $(aws efs describe-mount-targets --file-system-id $EFS_ID \
  --query 'MountTargets[*].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $MT_ID
done
sleep 60
aws efs delete-file-system --file-system-id $EFS_ID
aws ec2 delete-security-group --group-id $SG_ID

# Delete S3 bucket (uncomment to remove data)
# aws s3 rb s3://${S3_BUCKET} --force

# Delete ACM certificate
# aws acm delete-certificate --certificate-arn $CERT_ARN

# Delete IAM resources — eksctl-managed service accounts (controllers)
eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --namespace=kube-system --name=cluster-autoscaler
eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --namespace=kube-system --name=aws-load-balancer-controller
eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --namespace=kube-system --name=external-dns

# Delete IAM resources — manually-created IRSA roles (Platforma)
aws iam detach-role-policy \
  --role-name ${CLUSTER_NAME}-platforma-irsa \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-platforma-s3-access
aws iam delete-role --role-name ${CLUSTER_NAME}-platforma-irsa

aws iam detach-role-policy \
  --role-name ${CLUSTER_NAME}-platforma-jobs-irsa \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-platforma-s3-access
aws iam delete-role --role-name ${CLUSTER_NAME}-platforma-jobs-irsa

# Delete IAM policies
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-autoscaler-policy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-alb-controller-policy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-external-dns-policy
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-platforma-s3-access

# Delete cluster
eksctl delete cluster --name $CLUSTER_NAME
```
