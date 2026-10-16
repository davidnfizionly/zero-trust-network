# Administrative access: Session Manager on the EKS nodes. No SSH key on the node group,
# no bastion, no inbound rule added for administration. Every session is logged.

resource "aws_cloudwatch_log_group" "sessions" {
  name              = "/zero-trust/session-manager"
  retention_in_days = var.log_retention_days
}

# Account-level Session Manager preferences: the document name is fixed by the service.
resource "aws_ssm_document" "session_preferences" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences: every session streamed to CloudWatch Logs"
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.sessions.name
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = true
      s3BucketName                = ""
      idleSessionTimeout          = "20"
      maxSessionDuration          = "60"
      runAsEnabled                = false
      shellProfile = {
        linux   = "cd ~ && bash"
        windows = ""
      }
    }
  })
}

# Minimal agent permissions from the EKS best practices guide, instead of AmazonSSMManagedInstanceCore
# (which also grants Parameter Store reads). These actions do not support resource-level scoping (ADR-009).
resource "aws_iam_role_policy" "node_session_manager" {
  name = "session-manager-minimal"
  role = local.node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AgentRegistrationAndChannels"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
        ]
        Resource = "*"
      },
      {
        Sid      = "SessionLogDiscovery"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid      = "SessionLogWrite"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.sessions.arn}:*"
      },
    ]
  })
}
