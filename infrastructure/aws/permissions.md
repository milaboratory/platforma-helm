# AWS permissions reference

Permissions required for deploying and running Platforma on AWS EKS.

---

## 1. Deployer permissions

IAM actions required by the user or role deploying infrastructure (via CloudFormation or manually).

### EKS

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `eks:CreateCluster` | `*` | Create EKS cluster |
| `eks:DescribeCluster` | `*` | Read cluster configuration |
| `eks:DeleteCluster` | `*` | Cleanup |
| `eks:CreateNodegroup` | `*` | Create managed node groups |
| `eks:DeleteNodegroup` | `*` | Cleanup |
| `eks:DescribeNodegroup` | `*` | Read node group status |
| `eks:CreateAddon` | `*` | Install EBS/EFS CSI drivers |
| `eks:DescribeAddon` | `*` | Read addon status |
| `eks:DeleteAddon` | `*` | Cleanup |
| `eks:TagResource` | `*` | Tag cluster resources |

### EC2 / VPC

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `ec2:CreateVpc` | `*` | Create VPC (if not using existing) |
| `ec2:DeleteVpc` | `*` | Cleanup |
| `ec2:CreateSubnet` | `*` | Create public and private subnets |
| `ec2:DeleteSubnet` | `*` | Cleanup |
| `ec2:CreateSecurityGroup` | `*` | Security groups for EFS, cluster |
| `ec2:DeleteSecurityGroup` | `*` | Cleanup |
| `ec2:AuthorizeSecurityGroupIngress` | `*` | Allow NFS traffic to EFS |
| `ec2:RevokeSecurityGroupIngress` | `*` | Cleanup |
| `ec2:CreateInternetGateway` | `*` | Internet access for public subnets |
| `ec2:DeleteInternetGateway` | `*` | Cleanup |
| `ec2:AttachInternetGateway` | `*` | Attach IGW to VPC |
| `ec2:DetachInternetGateway` | `*` | Cleanup |
| `ec2:CreateNatGateway` | `*` | Outbound internet for private subnets |
| `ec2:DeleteNatGateway` | `*` | Cleanup |
| `ec2:AllocateAddress` | `*` | Elastic IP for NAT gateway |
| `ec2:ReleaseAddress` | `*` | Cleanup |
| `ec2:CreateRouteTable` | `*` | Routing for public/private subnets |
| `ec2:DeleteRouteTable` | `*` | Cleanup |
| `ec2:CreateRoute` | `*` | Route rules |
| `ec2:DeleteRoute` | `*` | Cleanup |
| `ec2:AssociateRouteTable` | `*` | Bind route tables to subnets |
| `ec2:DisassociateRouteTable` | `*` | Cleanup |
| `ec2:DescribeVpcs` | `*` | Read VPC state |
| `ec2:DescribeSubnets` | `*` | Read subnet state |
| `ec2:DescribeSecurityGroups` | `*` | Read security group state |
| `ec2:DescribeAvailabilityZones` | `*` | Discover AZs in region |
| `ec2:DescribeRouteTables` | `*` | Read routing state |
| `ec2:DescribeInternetGateways` | `*` | Read IGW state |
| `ec2:DescribeNatGateways` | `*` | Read NAT state |
| `ec2:DescribeAddresses` | `*` | Read EIP state |
| `ec2:CreateTags` | `*` | Tag resources |
| `ec2:CreateLaunchTemplate` | `*` | Node group launch templates |
| `ec2:DescribeLaunchTemplateVersions` | `*` | Read launch templates |
| `ec2:RunInstances` | `*` | Launch EC2 instances for node groups |

### EFS

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `elasticfilesystem:CreateFileSystem` | `*` | Create workspace filesystem |
| `elasticfilesystem:DeleteFileSystem` | `*` | Cleanup |
| `elasticfilesystem:DescribeFileSystems` | `*` | Read filesystem state |
| `elasticfilesystem:CreateMountTarget` | `*` | Mount targets per subnet |
| `elasticfilesystem:DeleteMountTarget` | `*` | Cleanup |
| `elasticfilesystem:DescribeMountTargets` | `*` | Read mount target state |
| `elasticfilesystem:TagResource` | `*` | Tag filesystem |

### S3

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `s3:CreateBucket` | `*` | Create primary storage bucket |
| `s3:DeleteBucket` | `*` | Cleanup |
| `s3:PutBucketEncryption` | `*` | Enable server-side encryption |
| `s3:PutBucketPublicAccessBlock` | `*` | Block public access |
| `s3:PutBucketVersioning` | `*` | Enable versioning |
| `s3:PutBucketPolicy` | `*` | Set S3 bucket policy (HTTPS enforcement, access restriction) |
| `s3:GetBucketPolicy` | `*` | Read bucket policy state |
| `s3:DeleteBucketPolicy` | `*` | Cleanup |

### ACM / Route53 (optional — only for TLS certificate)

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `acm:RequestCertificate` | `*` | Create ACM certificate |
| `acm:DescribeCertificate` | `*` | Read certificate status |
| `acm:DeleteCertificate` | `*` | Cleanup |
| `route53:ChangeResourceRecordSets` | Hosted zone | DNS validation records |
| `route53:GetChange` | `*` | Wait for DNS propagation |

### IAM

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `iam:CreateRole` | `*` | Cluster, node, IRSA roles |
| `iam:DeleteRole` | `*` | Cleanup |
| `iam:AttachRolePolicy` | `*` | Attach managed policies |
| `iam:DetachRolePolicy` | `*` | Cleanup |
| `iam:PutRolePolicy` | `*` | Inline policies for IRSA |
| `iam:DeleteRolePolicy` | `*` | Cleanup |
| `iam:CreatePolicy` | `*` | Custom policies (S3, autoscaler) |
| `iam:DeletePolicy` | `*` | Cleanup |
| `iam:GetRole` | `*` | Read role state |
| `iam:PassRole` | `*` | Pass roles to EKS/EC2 |
| `iam:CreateOpenIDConnectProvider` | `*` | OIDC for IRSA |
| `iam:DeleteOpenIDConnectProvider` | `*` | Cleanup |
| `iam:GetOpenIDConnectProvider` | `*` | Read OIDC state |
| `iam:GetPolicy` | `*` | Read managed policy state during updates |
| `iam:CreateServiceLinkedRole` | `*` | Service-linked roles for EKS/EFS |

### CloudFormation

Only needed when using the CloudFormation template (not for manual setup).

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `cloudformation:CreateStack` | `*` | Deploy the template |
| `cloudformation:DeleteStack` | `*` | Cleanup |
| `cloudformation:UpdateStack` | `*` | Update parameters |
| `cloudformation:DescribeStacks` | `*` | Read stack status |
| `cloudformation:DescribeStackEvents` | `*` | Debug deployment issues |
| `cloudformation:GetTemplate` | `*` | Read template |

---

## 2. EKS cluster role

The EKS cluster service role uses one AWS managed policy:

| Policy ARN | Purpose |
|-----------|---------|
| `arn:aws:iam::aws:policy/AmazonEKSClusterPolicy` | Allows EKS to manage cluster resources (ENIs, security groups, logging) |

Trust policy allows `eks.amazonaws.com` to assume this role.

---

## 3. Node group role

All managed node groups share a single IAM role with these AWS managed policies:

| Policy ARN | Purpose |
|-----------|---------|
| `arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy` | Node registration with the EKS API server |
| `arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy` | VPC CNI plugin — pod networking and IP allocation |
| `arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly` | Pull container images from Amazon ECR |

Trust policy allows `ec2.amazonaws.com` to assume this role.

**Note:** CSI driver policies are no longer on the node group role. EBS and EFS CSI drivers use dedicated IRSA roles (see section 4).

---

## 4. CSI driver service accounts (IRSA)

Each CSI driver has a dedicated IRSA role instead of broad node-level policies.

### EBS CSI driver

Bound to Kubernetes service account `ebs-csi-controller-sa` in namespace `kube-system` via OIDC federation.

| Policy ARN | Purpose |
|-----------|---------|
| `arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy` | Provision and manage EBS volumes (gp3 for database/main storage) |

The role ARN is configured via `ServiceAccountRoleArn` on the EKS addon — no manual SA annotation needed.

### EFS CSI driver

Bound to Kubernetes service account `efs-csi-controller-sa` in namespace `kube-system` via OIDC federation.

| Policy ARN | Purpose |
|-----------|---------|
| `arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy` | Mount EFS filesystems for shared workspace |

The role ARN is configured via `ServiceAccountRoleArn` on the EKS addon — no manual SA annotation needed.

---

## 5. Platforma service account (IRSA)

Bound to Kubernetes service account `platforma` in namespace `platforma` via OIDC federation. All permissions scoped to a single S3 bucket.

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `s3:ListBucket` | `arn:aws:s3:::<bucket>` | List objects in bucket |
| `s3:ListBucketMultipartUploads` | `arn:aws:s3:::<bucket>` | List in-progress multipart uploads |
| `s3:GetObject` | `arn:aws:s3:::<bucket>/*` | Read objects |
| `s3:PutObject` | `arn:aws:s3:::<bucket>/*` | Write objects |
| `s3:DeleteObject` | `arn:aws:s3:::<bucket>/*` | Delete objects |
| `s3:GetObjectAttributes` | `arn:aws:s3:::<bucket>/*` | Get object metadata |
| `s3:AbortMultipartUpload` | `arn:aws:s3:::<bucket>/*` | Clean up failed multipart uploads |
| `s3:ListMultipartUploadParts` | `arn:aws:s3:::<bucket>/*` | List parts of multipart uploads |

No wildcard bucket resources. The IAM policy is scoped to the specific bucket created during infrastructure setup.

The CloudFormation template also creates an S3 bucket policy that enforces HTTPS and restricts access to the Platforma IRSA role and account administrators (using `StringNotLike` on `aws:PrincipalArn`).

---

## 6. Cluster Autoscaler service account (IRSA)

Bound to Kubernetes service account `cluster-autoscaler` in namespace `kube-system` via OIDC federation.

**Read-only (all resources):**

| Permission | Resource | Purpose |
|-----------|----------|---------|
| `autoscaling:DescribeAutoScalingGroups` | `*` | Discover node groups and their current state |
| `autoscaling:DescribeAutoScalingInstances` | `*` | Get instance status within ASGs |
| `autoscaling:DescribeLaunchConfigurations` | `*` | Read launch configurations |
| `autoscaling:DescribeScalingActivities` | `*` | Monitor scaling operations |
| `autoscaling:DescribeTags` | `*` | Discover ASGs by autodiscovery tags |
| `ec2:DescribeImages` | `*` | AMI lookup |
| `ec2:DescribeInstanceTypes` | `*` | Instance type capabilities (CPU, memory) |
| `ec2:DescribeLaunchTemplateVersions` | `*` | Read launch templates |
| `ec2:GetInstanceTypesFromInstanceRequirements` | `*` | Instance type filtering |
| `eks:DescribeNodegroup` | `*` | Read managed node group configuration |

**Write (scoped to tagged ASGs):**

| Permission | Resource | Condition | Purpose |
|-----------|----------|-----------|---------|
| `autoscaling:SetDesiredCapacity` | `*` | `aws:ResourceTag/k8s.io/cluster-autoscaler/<cluster>=owned` | Scale node groups up/down |
| `autoscaling:TerminateInstanceInAutoScalingGroup` | `*` | Same tag condition | Remove nodes during scale-down |

Write actions are restricted to ASGs tagged with the cluster's autoscaler ownership tag.

---

## 7. AWS Load Balancer Controller (IRSA)

Bound to Kubernetes service account `aws-load-balancer-controller` in namespace `kube-system` via OIDC federation.

Full policy sourced from [aws-load-balancer-controller v2.11.0](https://github.com/kubernetes-sigs/aws-load-balancer-controller). Contains 15 statements covering:

| Category | Actions | Resource scope |
|----------|---------|---------------|
| Service-linked role | `iam:CreateServiceLinkedRole` | Condition: `elasticloadbalancing.amazonaws.com` |
| EC2 describe | VPCs, subnets, security groups, instances, tags, COIP pools | `*` (read-only) |
| ELB describe | Load balancers, listeners, target groups, trust stores, attributes | `*` (read-only) |
| ACM / WAF / Shield | `acm:ListCertificates`, `acm:DescribeCertificate`, WAFv2, Shield | `*` (read-only) |
| Security group management | Create, authorize/revoke ingress, delete, tag | Scoped to `elbv2.k8s.aws/cluster` tag |
| Load balancer lifecycle | Create, modify, delete load balancers and target groups | Scoped to `elbv2.k8s.aws/cluster` tag |
| Listener/rule management | Create/delete listeners and rules | `*` |
| Target registration | Register/deregister targets | Target group ARN |

---

## 8. Kubernetes RBAC

The Helm chart creates a `Role` and `RoleBinding` in the release namespace granting the Platforma service account access to: pods, jobs, configmaps, secrets, events, persistentvolumeclaims. No cluster-level permissions.
