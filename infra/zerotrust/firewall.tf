# Phases 3 and 4: one inspected path in and out of the VPC.
#
# Internet -> IGW -> (edge route table) -> firewall endpoint -> public subnets (load balancer, NAT)
# Public subnets -> 0.0.0.0/1 and 128.0.0.0/1 -> firewall endpoint -> firewall subnet -> IGW
#
# The two /1 routes are more specific than the baseline 0.0.0.0/0 route to the IGW, so all
# internet-bound traffic from the public subnets is inspected without modifying a route the
# baseline stack owns (ADR-007).

resource "aws_subnet" "firewall" {
  vpc_id                  = local.vpc_id
  cidr_block              = var.firewall_subnet_cidr
  availability_zone       = local.primary_az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.workload_name}-firewall-${local.primary_az}"
  }
}

resource "aws_route_table" "firewall" {
  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.workload.id
  }

  tags = {
    Name = "${var.workload_name}-firewall"
  }
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

resource "aws_networkfirewall_rule_group" "zero_trust" {
  name     = "${var.workload_name}-zero-trust"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = [local.vpc_cidr]
        }
      }
    }

    rules_source {
      rules_string = templatefile("${path.module}/rules/zero-trust.rules.tftpl", {
        allowed_domains = var.egress_allowed_domains
      })
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "zero_trust" {
  name = "${var.workload_name}-zero-trust"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    # Default deny: anything no rule passes is dropped once the connection is established,
    # and logged to the alert log. The application-layer variants let a segmented TLS Client
    # Hello through until its SNI is visible, so the domain allowlist can be evaluated
    # (plain drop_established can drop the first packet before the SNI is parsed).
    stateful_default_actions = ["aws:drop_established_app_layer", "aws:alert_established_app_layer"]

    stateful_rule_group_reference {
      priority     = 100
      resource_arn = aws_networkfirewall_rule_group.zero_trust.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "zero_trust" {
  name                = "${var.workload_name}-zero-trust"
  vpc_id              = local.vpc_id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.zero_trust.arn

  delete_protection                 = false
  subnet_change_protection          = false
  firewall_policy_change_protection = false

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }
}

locals {
  firewall_endpoint_id = one([
    for s in aws_networkfirewall_firewall.zero_trust.firewall_status[0].sync_states :
    s.attachment[0].endpoint_id
  ])
}

# Ingress routing: traffic arriving at the IGW for the public subnets goes to the firewall first.
resource "aws_route_table" "igw_edge" {
  vpc_id = local.vpc_id

  tags = {
    Name = "${var.workload_name}-igw-edge"
  }
}

resource "aws_route" "igw_edge_to_firewall" {
  for_each = toset(local.public_subnet_cidrs)

  route_table_id         = aws_route_table.igw_edge.id
  destination_cidr_block = each.value
  vpc_endpoint_id        = local.firewall_endpoint_id
}

resource "aws_route_table_association" "igw_edge" {
  gateway_id     = data.aws_internet_gateway.workload.id
  route_table_id = aws_route_table.igw_edge.id
}

# Return and egress path: public subnets reach the internet only through the firewall.
resource "aws_route" "public_to_firewall" {
  for_each = toset(["0.0.0.0/1", "128.0.0.0/1"])

  route_table_id         = data.aws_route_table.public.id
  destination_cidr_block = each.value
  vpc_endpoint_id        = local.firewall_endpoint_id
}

resource "aws_cloudwatch_log_group" "firewall_alert" {
  name              = "/zero-trust/network-firewall/alert"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "firewall_flow" {
  name              = "/zero-trust/network-firewall/flow"
  retention_in_days = 7
}

resource "aws_networkfirewall_logging_configuration" "zero_trust" {
  firewall_arn = aws_networkfirewall_firewall.zero_trust.arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_alert.name
      }
    }

    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall_flow.name
      }
    }
  }
}
