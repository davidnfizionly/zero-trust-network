# Phase 8: the workload roles keep their original allow policies, and each gets an explicit
# deny that applies whenever a call does not come through this VPC's endpoints. Credentials
# taken out of a pod (for example a service account token exchanged elsewhere) are useless
# outside the VPC. An explicit deny always wins over an allow, so this tightens the baseline
# roles without editing the policies the baseline stack owns.

data "aws_iam_role" "service" {
  for_each = toset(local.services)
  name     = "${var.workload_name}-${each.key}-irsa"
}

locals {
  dynamodb_table_actions = [
    "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
    "dynamodb:Query", "dynamodb:Scan", "dynamodb:DescribeTable",
    "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem",
  ]
  dynamodb_stream_actions = [
    "dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams",
  ]

  # Which context condition applies to which role, based on what each service calls.
  deny_rules = {
    wallet = {
      dynamodb = true, streams = false, events = false, sqs = false
    }
    transaction = {
      dynamodb = true, streams = false, events = true, sqs = false
    }
    fraud-detection = {
      dynamodb = true, streams = true, events = true, sqs = false
    }
    notification = {
      dynamodb = false, streams = false, events = false, sqs = true
    }
    reconciliation = {
      dynamodb = true, streams = false, events = false, sqs = true
    }
  }
}

data "aws_iam_policy_document" "network_context" {
  for_each = local.deny_rules

  # Table calls must arrive through the DynamoDB gateway endpoint of this VPC.
  dynamic "statement" {
    for_each = each.value.dynamodb ? [1] : []
    content {
      sid       = "DenyDynamoDBOutsideGatewayEndpoint"
      effect    = "Deny"
      actions   = local.dynamodb_table_actions
      resources = ["*"]
      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpce"
        values   = [aws_vpc_endpoint.dynamodb.id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.value.streams ? [1] : []
    content {
      sid       = "DenyStreamsOutsideVpc"
      effect    = "Deny"
      actions   = local.dynamodb_stream_actions
      resources = ["*"]
      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpc"
        values   = [local.vpc_id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.value.events ? [1] : []
    content {
      sid       = "DenyEventsOutsideVpc"
      effect    = "Deny"
      actions   = ["events:PutEvents"]
      resources = ["*"]
      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpc"
        values   = [local.vpc_id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.value.sqs ? [1] : []
    content {
      sid       = "DenySqsOutsideVpc"
      effect    = "Deny"
      actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
      resources = ["*"]
      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpc"
        values   = [local.vpc_id]
      }
    }
  }
}

resource "aws_iam_role_policy" "network_context" {
  for_each = local.deny_rules

  name   = "deny-outside-vpc-endpoints"
  role   = data.aws_iam_role.service[each.key].name
  policy = data.aws_iam_policy_document.network_context[each.key].json
}
