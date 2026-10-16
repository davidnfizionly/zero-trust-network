# Private paths to the AWS APIs the workload and the nodes actually call.
# Gateway endpoints for S3 and DynamoDB, interface endpoints (PrivateLink) for the rest.

locals {
  interface_services = {
    "ecr.api"          = "image pulls (registry API)"
    "ecr.dkr"          = "image pulls (Docker registry)"
    "sts"              = "IRSA web identity token exchange"
    "sqs"              = "notification and reconciliation queues"
    "events"           = "EventBridge PutEvents"
    "dynamodb-streams" = "fraud-detection stream reader"
    "logs"             = "Session Manager session logs"
    "ec2"              = "VPC CNI address management"
    "ssm"              = "Session Manager"
    "ssmmessages"      = "Session Manager data channel"
    "ec2messages"      = "Systems Manager agent messages"
  }

  # dynamodb-streams has no private DNS name: clients use the endpoint DNS name explicitly.
  no_private_dns = ["dynamodb-streams"]
}

resource "aws_security_group" "endpoints" {
  name        = "${var.workload_name}-vpc-endpoints"
  description = "Interface endpoints: HTTPS from inside the VPC only"
  vpc_id      = data.aws_vpc.workload.id

  tags = {
    Name = "${var.workload_name}-vpc-endpoints"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from the VPC"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services

  vpc_id              = data.aws_vpc.workload.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = sort(data.aws_subnets.private.ids)
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = !contains(local.no_private_dns, each.key)

  tags = {
    Name    = "${var.workload_name}-${each.key}"
    Purpose = each.value
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = data.aws_vpc.workload.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  # Only this account's tables are reachable through the endpoint.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OwnAccountTablesOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "dynamodb:*"
      Resource  = "arn:aws:dynamodb:${var.aws_region}:${local.account_id}:table/${var.workload_name}-*"
    }]
  })

  tags = {
    Name = "${var.workload_name}-dynamodb"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.workload.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  # ECR stores image layers in an AWS-owned bucket; that is the only S3 access the nodes need.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EcrImageLayersOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:::prod-${var.aws_region}-starport-layer-bucket/*"
    }]
  })

  tags = {
    Name = "${var.workload_name}-s3"
  }
}
