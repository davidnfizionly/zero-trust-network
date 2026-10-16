# Threat detection and aggregated findings.
# GuardDuty sends its findings to Security Hub CSPM natively. Network Firewall does not (it is not in
# the list of AWS services that send findings), so blocked firewall alerts are turned into custom
# findings by a small function subscribed to the alert log group (ADR-010).

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RUNTIME_MONITORING"
  status      = "DISABLED"
}

resource "aws_securityhub_account" "this" {
  # No standards: their controls need AWS Config recording, outside this project's scope (ADR-011).
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = false
}

# --- Network Firewall alerts to Security Hub custom findings

data "archive_file" "firewall_findings" {
  type        = "zip"
  source_file = "${path.module}/lambda/firewall_findings.py"
  output_path = "${path.module}/.build/firewall_findings.zip"
}

resource "aws_cloudwatch_log_group" "firewall_findings_fn" {
  name              = "/aws/lambda/${var.workload_name}-firewall-findings"
  retention_in_days = var.log_retention_days
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

resource "aws_iam_role_policy" "firewall_findings" {
  name = "import-firewall-findings"
  role = aws_iam_role.firewall_findings.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "OwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.firewall_findings_fn.arn}:*"
      },
      {
        Sid      = "ImportIntoOwnProductOnly"
        Effect   = "Allow"
        Action   = ["securityhub:BatchImportFindings"]
        Resource = "arn:aws:securityhub:${var.aws_region}:${local.account_id}:product/${local.account_id}/default"
      },
    ]
  })
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
      FIREWALL_ARN = aws_networkfirewall_firewall.this.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.firewall_findings_fn, aws_securityhub_account.this]
}

resource "aws_lambda_permission" "firewall_alert_logs" {
  statement_id   = "AllowFirewallAlertLogs"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.firewall_findings.function_name
  principal      = "logs.amazonaws.com"
  source_arn     = "${aws_cloudwatch_log_group.firewall_alert.arn}:*"
  source_account = local.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "firewall_blocked" {
  name            = "blocked-to-security-hub"
  log_group_name  = aws_cloudwatch_log_group.firewall_alert.name
  filter_pattern  = "{ $.event.alert.action = \"blocked\" }"
  destination_arn = aws_lambda_function.firewall_findings.arn

  depends_on = [aws_lambda_permission.firewall_alert_logs]
}
