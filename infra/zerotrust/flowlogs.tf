# VPC Flow Logs with the version 5 fields that show where a packet actually went:
# pkt-dst-aws-service names the AWS service, traffic-path 7 means "through a gateway VPC endpoint"
# and 8 means "through an internet gateway".

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/zero-trust/vpc-flow-logs"
  retention_in_days = 7
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.workload_name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-vpc-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "workload" {
  vpc_id                   = local.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  log_format = join(" ", [
    "$${version}", "$${interface-id}", "$${srcaddr}", "$${dstaddr}", "$${srcport}", "$${dstport}",
    "$${protocol}", "$${packets}", "$${bytes}", "$${start}", "$${end}", "$${action}", "$${log-status}",
    "$${subnet-id}", "$${pkt-srcaddr}", "$${pkt-dstaddr}", "$${pkt-dst-aws-service}",
    "$${flow-direction}", "$${traffic-path}",
  ])
}
