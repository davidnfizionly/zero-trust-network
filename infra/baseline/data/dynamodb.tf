resource "aws_dynamodb_table" "wallets" {
  name         = "${var.project_name}-wallets"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "wallet_id"

  attribute {
    name = "wallet_id"
    type = "S"
  }

  tags = {
    Workload = var.project_name
  }
}

resource "aws_dynamodb_table" "transactions" {
  name         = "${var.project_name}-transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "transaction_id"

  attribute {
    name = "transaction_id"
    type = "S"
  }

  attribute {
    name = "idempotency_key"
    type = "S"
  }

  global_secondary_index {
    name            = "idempotency_key-index"
    hash_key        = "idempotency_key"
    projection_type = "ALL"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = {
    Workload = var.project_name
  }
}

resource "aws_dynamodb_table" "fraud_events" {
  name         = "${var.project_name}-fraud-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = {
    Workload = var.project_name
  }
}
