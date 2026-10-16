# Phase 6: administrative access through Session Manager only. No SSH key on the node group,
# no bastion, no inbound rule for administration. Sessions are recorded in S3 through the
# gateway endpoint.

data "aws_eks_node_groups" "workload" {
  cluster_name = data.aws_eks_cluster.workload.name
}

data "aws_eks_node_group" "workload" {
  for_each = data.aws_eks_node_groups.workload.names

  cluster_name    = data.aws_eks_cluster.workload.name
  node_group_name = each.value
}

locals {
  node_role_names = toset([
    for ng in data.aws_eks_node_group.workload : element(split("/", ng.node_role_arn), length(split("/", ng.node_role_arn)) - 1)
  ])
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  for_each = local.node_role_names

  role       = each.value
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_s3_bucket" "session_logs" {
  bucket_prefix = "zero-trust-session-logs-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "session_logs" {
  bucket = aws_s3_bucket.session_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "node_session_logs" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.session_logs.arn}/sessions/*"]
  }

  statement {
    actions   = ["s3:GetEncryptionConfiguration"]
    resources = [aws_s3_bucket.session_logs.arn]
  }
}

resource "aws_iam_role_policy" "node_session_logs" {
  for_each = local.node_role_names

  name   = "write-session-logs"
  role   = each.value
  policy = data.aws_iam_policy_document.node_session_logs.json
}

# Account-level Session Manager preferences: every shell session is recorded.
resource "aws_ssm_document" "session_preferences" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences: sessions recorded to S3, encrypted transport, idle timeout"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName           = aws_s3_bucket.session_logs.id
      s3KeyPrefix            = "sessions"
      s3EncryptionEnabled    = true
      cloudWatchLogGroupName = ""
      kmsKeyId               = ""
      runAsEnabled           = false
      idleSessionTimeout     = "20"
      shellProfile = {
        linux = "cd /tmp && echo \"Recorded session on $(hostname) at $(date -u +%FT%TZ)\""
      }
    }
  })
}
