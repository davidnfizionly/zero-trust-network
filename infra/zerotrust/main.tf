# Zero trust retrofit of the payment platform network.
# Every existing resource is looked up by name or tag: this stack only adds controls
# around the baseline, it never re-creates or imports baseline resources.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {
    key = "zerotrust/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "zero-trust"
      Stack     = "zerotrust"
      ManagedBy = "terraform"
    }
  }
}

variable "aws_region" {
  description = "Region of the baseline workload"
  type        = string
  default     = "us-east-1"
}

variable "workload_name" {
  description = "Name prefix of the baseline workload resources"
  type        = string
  default     = "payment-platform"
}

variable "firewall_subnet_cidr" {
  description = "CIDR of the dedicated firewall subnet (inside the baseline VPC CIDR, unused by the baseline)"
  type        = string
  default     = "10.0.20.0/28"
}

variable "egress_allowed_domains" {
  description = "Domains the workload may reach over TLS through the NAT path. Everything else is dropped."
  type        = list(string)
  default = [
    # Istio sidecar and gateway images are pulled from Docker Hub when a pod starts.
    ".docker.io",
    "production.cloudflare.docker.com",
  ]
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "workload" {
  tags = {
    Name = "${var.workload_name}-vpc"
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

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.workload.id]
  }
  tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

data "aws_route_table" "public" {
  vpc_id = data.aws_vpc.workload.id
  tags = {
    Name = "${var.workload_name}-vpc-public"
  }
}

data "aws_route_table" "private" {
  vpc_id = data.aws_vpc.workload.id
  tags = {
    Name = "${var.workload_name}-vpc-private"
  }
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

locals {
  account_id = data.aws_caller_identity.current.account_id
  vpc_id     = data.aws_vpc.workload.id
  vpc_cidr   = data.aws_vpc.workload.cidr_block

  # Single-AZ placement for the firewall endpoint and the interface endpoints (ADR-005).
  primary_az = sort([for s in data.aws_subnet.private : s.availability_zone])[0]
  primary_private_subnet = one([
    for s in data.aws_subnet.private : s.id if s.availability_zone == local.primary_az
  ])
  public_subnet_cidrs = sort([for s in data.aws_subnet.public : s.cidr_block])

  services = ["wallet", "transaction", "fraud-detection", "notification", "reconciliation"]
}
