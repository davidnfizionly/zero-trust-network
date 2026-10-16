# The baseline stacks are read through tags and names, not through their remote state,
# so this stack needs no state bucket name in code.

data "aws_caller_identity" "current" {}

data "aws_vpc" "workload" {
  tags = {
    Name    = "${var.workload_name}-vpc"
    Project = "zero-trust"
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.workload.id]
  }
  tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.workload.id]
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_route_table" "public" {
  # The VPC module uses one route table for all public subnets.
  subnet_id = sort(data.aws_subnets.public.ids)[0]
}

data "aws_route_table" "private" {
  for_each  = toset(data.aws_subnets.private.ids)
  subnet_id = each.value
}

data "aws_internet_gateway" "workload" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.workload.id]
  }
}

data "aws_eks_cluster" "workload" {
  name = "${var.workload_name}-eks"
}

data "aws_eks_node_groups" "workload" {
  cluster_name = data.aws_eks_cluster.workload.name
}

data "aws_eks_node_group" "workload" {
  cluster_name    = data.aws_eks_cluster.workload.name
  node_group_name = one(data.aws_eks_node_groups.workload.names)
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  vpc_cidr   = data.aws_vpc.workload.cidr_block

  public_cidrs = sort([for s in data.aws_subnet.public : s.cidr_block])

  # One firewall endpoint, in the AZ of the single NAT gateway of the original design (ADR-007).
  firewall_az = data.aws_subnet.public[sort(data.aws_subnets.public.ids)[0]].availability_zone

  node_role_name = element(split("/", data.aws_eks_node_group.workload.node_role_arn), 1)

  private_route_table_ids = distinct([for rt in data.aws_route_table.private : rt.id])
}
