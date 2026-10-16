# Phase 7: GuardDuty and Security Hub CSPM.
# Network Firewall is not a native finding source for Security Hub CSPM (checked against the
# "AWS service integrations with Security Hub CSPM" page), so a small Lambda function turns
# firewall alert log entries into custom findings (ADR-009).

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

# Runtime monitoring would install an agent on the two small nodes; left off (ADR-010).
resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RUNTIME_MONITORING"
  status      = "DISABLED"

  # GuardDuty adds disabled agent-management sub-settings on its own; they are not managed here.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

resource "aws_securityhub_account" "this" {
  enable_default_standards  = true
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

# --- Network Firewall alerts -> Security Hub CSPM custom findings ---

data "archive_file" "firewall_findings" {
  type        = "zip"
  source_file = "${path.module}/lambda/firewall_findings.py"
  output_path = "${path.module}/.build/firewall_findings.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firewall_findings" {
  name               = "${var.workload_name}-firewall-findings"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_cloudwatch_log_group" "firewall_findings" {
  name              = "/aws/lambda/${var.workload_name}-firewall-findings"
  retention_in_days = 7
}

data "aws_iam_policy_document" "firewall_findings" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firewall_findings.arn}:*"]
  }

  statement {
    actions = ["securityhub:BatchImportFindings"]
    resources = [
      "arn:aws:securityhub:${var.aws_region}:${local.account_id}:product/${local.account_id}/default",
    ]
  }
}

resource "aws_iam_role_policy" "firewall_findings" {
  name   = "import-firewall-findings"
  role   = aws_iam_role.firewall_findings.id
  policy = data.aws_iam_policy_document.firewall_findings.json
}

resource "aws_lambda_function" "firewall_findings" {
  function_name    = "${var.workload_name}-firewall-findings"
  role             = aws_iam_role.firewall_findings.arn
  runtime          = "python3.13"
  handler          = "firewall_findings.handler"
  filename         = data.archive_file.firewall_findings.output_path
  source_code_hash = data.archive_file.firewall_findings.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      FIREWALL_ARN = aws_networkfirewall_firewall.zero_trust.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.firewall_findings, aws_securityhub_account.this]
}

resource "aws_lambda_permission" "firewall_findings_logs" {
  statement_id  = "AllowFirewallAlertLogSubscription"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.firewall_findings.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.firewall_alert.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "firewall_alerts" {
  name            = "firewall-alerts-to-security-hub"
  log_group_name  = aws_cloudwatch_log_group.firewall_alert.name
  filter_pattern  = "{ $.event.event_type = \"alert\" }"
  destination_arn = aws_lambda_function.firewall_findings.arn

  depends_on = [aws_lambda_permission.firewall_findings_logs]
}
