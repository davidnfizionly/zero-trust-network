# VPC Flow Logs with the fields that show the path a packet took:
# pkt-dst-aws-service names the AWS service, traffic-path 7 means "through a gateway VPC endpoint".

resource "aws_cloudwatch_log_group" "flow" {
  name              = "/zero-trust/vpc-flow-logs"
  retention_in_days = var.log_retention_days
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

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-log-group"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = data.aws_vpc.workload.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  log_format = join(" ", [
    "$${interface-id}", "$${srcaddr}", "$${dstaddr}", "$${srcport}", "$${dstport}", "$${protocol}",
    "$${packets}", "$${bytes}", "$${start}", "$${end}", "$${action}", "$${log-status}",
    "$${subnet-id}", "$${instance-id}", "$${pkt-srcaddr}", "$${pkt-dstaddr}",
    "$${pkt-dst-aws-service}", "$${flow-direction}", "$${traffic-path}",
  ])
}
