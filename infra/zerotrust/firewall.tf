resource "aws_networkfirewall_rule_group" "zero_trust" {
  name     = "${var.workload_name}-zero-trust"
  type     = "STATEFUL"
  capacity = 200

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = [local.vpc_cidr]
        }
      }
      ip_sets {
        key = "EDGE_NET"
        ip_set {
          definition = local.public_cidrs
        }
      }
    }

    rules_source {
      rules_string = templatefile("${path.module}/rules/zero-trust.rules.tftpl", {
        egress_allowed_domains = var.egress_allowed_domains
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

    # Anything no rule passed is dropped once the connection is established, and logged as an alert.
    stateful_default_actions = ["aws:drop_established", "aws:alert_established"]

    stateful_rule_group_reference {
      priority     = 1
      resource_arn = aws_networkfirewall_rule_group.zero_trust.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "this" {
  name                = "${var.workload_name}-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.zero_trust.arn
  vpc_id              = data.aws_vpc.workload.id

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }

  delete_protection                 = false
  subnet_change_protection          = false
  firewall_policy_change_protection = false
}

resource "aws_cloudwatch_log_group" "firewall_alert" {
  name              = "/zero-trust/network-firewall/alert"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "firewall_flow" {
  name              = "/zero-trust/network-firewall/flow"
  retention_in_days = var.log_retention_days
}

resource "aws_networkfirewall_logging_configuration" "this" {
  firewall_arn = aws_networkfirewall_firewall.this.arn

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
