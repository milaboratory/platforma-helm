# =============================================================================
# Networking — new VPC (default) or bring-your-own subnets
# =============================================================================
# CreateNewVpc toggle mirrors the CloudFormation template: leave var.vpc_id
# empty to create a /16 VPC with 3 public + 3 private /19 subnets across 3 AZs,
# a single NAT gateway, and the route tables. Set var.vpc_id (+ subnet IDs) to
# deploy into existing networking — the customer is then responsible for the
# subnet ELB tags (kubernetes.io/role/elb, internal-elb) and NAT egress.
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  create_vpc = var.vpc_id == ""
  az_names   = slice(data.aws_availability_zones.available.names, 0, 3)

  # /19 subnets carved from the VPC CIDR. cidrsubnet(cidr, 3, i) adds 3 bits to
  # a /16 → /19, reproducing CF's Fn::Cidr[VpcCidr, 6, 13]: public take indices
  # 0-2, private take 3-5.
  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 3, i)]
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 3, i + 3)]
}

resource "aws_vpc" "this" {
  count                = local.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = { Name = "${var.cluster_name}-igw" }
}

# Public subnets — ALB lives here; tagged for the AWS Load Balancer Controller.
resource "aws_subnet" "public" {
  count                   = local.create_vpc ? 3 : 0
  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.az_names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private subnets — worker nodes and EFS mount targets.
resource "aws_subnet" "private" {
  count             = local.create_vpc ? 3 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.az_names[count.index]

  tags = {
    Name                              = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route" "public_internet" {
  count                  = local.create_vpc ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count          = local.create_vpc ? 3 : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Single NAT gateway. AWS auto-recovers it in ~3-5 min on failure; a per-AZ NAT
# (3x cost) is rarely worth it for this workload. Matches the CF template.
resource "aws_eip" "nat" {
  count  = local.create_vpc ? 1 : 0
  domain = "vpc"

  tags = { Name = "${var.cluster_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = local.create_vpc ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${var.cluster_name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = { Name = "${var.cluster_name}-private-rt" }
}

resource "aws_route" "private_nat" {
  count                  = local.create_vpc ? 1 : 0
  route_table_id         = aws_route_table.private[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = local.create_vpc ? 3 : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# -----------------------------------------------------------------------------
# Resolved network identifiers — consumed by eks.tf, nodegroups.tf, storage.tf.
# Resolve to the created resources or the bring-your-own variables.
# -----------------------------------------------------------------------------
locals {
  resolved_vpc_id             = local.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  resolved_private_subnet_ids = local.create_vpc ? aws_subnet.private[*].id : var.private_subnet_ids
  resolved_public_subnet_ids  = local.create_vpc ? aws_subnet.public[*].id : var.public_subnet_ids

  # EKS gets private + public subnets (public only if provided). Public subnets
  # let the cluster place internet-facing ALBs; private host the nodes.
  cluster_subnet_ids = concat(local.resolved_private_subnet_ids, local.resolved_public_subnet_ids)
}
