# Phase 5: AWS API calls from the workload stay on the AWS network.
# Gateway endpoints (no hourly charge) for DynamoDB and S3 (ECR image layers, session logs),
# interface endpoints only for the services the workload and the nodes actually call (ADR-008).

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private.id]

  tags = {
    Name = "${var.workload_name}-dynamodb"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.private.id]

  tags = {
    Name = "${var.workload_name}-s3"
  }
}

locals {
  interface_endpoints = {
    # Image pulls
    "ecr.api" = "ECR API (image manifests)"
    "ecr.dkr" = "ECR registry (image pulls)"
    # Node networking (VPC CNI assigns pod IPs through the EC2 API)
    "ec2" = "EC2 API (VPC CNI)"
    # IRSA: pods exchange their service account token for role credentials
    "sts" = "STS (IRSA web identity)"
    # Workload calls
    "events"           = "EventBridge (transaction events)"
    "sqs"              = "SQS (notification and reconciliation queues)"
    "dynamodb-streams" = "DynamoDB Streams (fraud detection)"
    # Session Manager
    "ssm"         = "Systems Manager"
    "ssmmessages" = "Session Manager data channel"
    "ec2messages" = "Systems Manager agent messages"
  }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.workload_name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to the interface endpoints"
  vpc_id      = local.vpc_id

  tags = {
    Name = "${var.workload_name}-vpc-endpoints"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from the VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = local.vpc_cidr
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [local.primary_private_subnet]
  security_group_ids  = [aws_security_group.endpoints.id]

  tags = {
    Name    = "${var.workload_name}-${each.key}"
    Purpose = each.value
  }
}
