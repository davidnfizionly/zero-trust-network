resource "aws_sqs_queue" "notification_queue" {
  name                      = "${var.project_name}-notification-queue"
  message_retention_seconds = 3600

  tags = {
    Workload = var.project_name
  }
}

resource "aws_sqs_queue_policy" "notification_queue_policy" {
  queue_url = aws_sqs_queue.notification_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.notification_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_bus.payment_events.arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "notification_on_confirmed" {
  rule           = aws_cloudwatch_event_rule.transaction_confirmed.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "notification-queue-confirmed"
  arn            = aws_sqs_queue.notification_queue.arn
}

resource "aws_cloudwatch_event_target" "notification_on_fraud" {
  rule           = aws_cloudwatch_event_rule.fraud_detected.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "notification-queue-fraud"
  arn            = aws_sqs_queue.notification_queue.arn
}

resource "aws_sqs_queue" "reconciliation_queue" {
  name                      = "${var.project_name}-reconciliation-queue"
  message_retention_seconds = 3600

  tags = {
    Workload = var.project_name
  }
}

resource "aws_sqs_queue_policy" "reconciliation_queue_policy" {
  queue_url = aws_sqs_queue.reconciliation_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.reconciliation_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_bus.payment_events.arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "reconciliation_on_lifecycle" {
  rule           = aws_cloudwatch_event_rule.transaction_lifecycle.name
  event_bus_name = aws_cloudwatch_event_bus.payment_events.name
  target_id      = "reconciliation-queue"
  arn            = aws_sqs_queue.reconciliation_queue.arn
}

output "notification_queue_url" {
  value = aws_sqs_queue.notification_queue.url
}

output "reconciliation_queue_url" {
  value = aws_sqs_queue.reconciliation_queue.url
}
