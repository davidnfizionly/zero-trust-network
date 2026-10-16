# Context conditions on the existing workload roles. The baseline allow policies stay as they were;
# an added explicit deny refuses any data-plane call that does not arrive through this VPC's endpoints.
# A stolen web identity token used from outside the VPC can still assume the role, but every
# DynamoDB, SQS and EventBridge call it makes is denied.

locals {
  workload_services = ["wallet", "transaction", "fraud-detection", "notification", "reconciliation"]
}

resource "aws_iam_role_policy" "deny_outside_vpc" {
  for_each = toset(local.workload_services)

  name = "deny-outside-workload-vpc"
  role = "${var.workload_name}-${each.key}-irsa"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyDataCallsOutsideWorkloadVpc"
      Effect   = "Deny"
      Action   = ["dynamodb:*", "sqs:*", "events:*"]
      Resource = "*"
      Condition = {
        StringNotEquals = {
          "aws:SourceVpc" = data.aws_vpc.workload.id
        }
      }
    }]
  })
}
