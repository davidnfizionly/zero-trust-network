module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "${var.project_name}-eks"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Original value: true. The zero trust retrofit sets zero_trust_private_api=true (ADR-006).
  cluster_endpoint_public_access  = !var.zero_trust_private_api
  cluster_endpoint_private_access = true

  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      min_size     = 2
      max_size     = 3
      desired_size = var.node_desired_size

      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      labels = {
        role = "general"
      }

      tags = {
        Project  = "zero-trust"
        Workload = var.project_name
      }
    }
  }

  node_security_group_additional_rules = {
    ingress_istio_webhook = {
      description                   = "Cluster API Server to Istio webhook (istiod)"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Workload  = var.project_name
    ManagedBy = "terraform"
  }
}
