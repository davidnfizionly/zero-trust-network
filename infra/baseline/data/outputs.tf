output "wallets_table_name" {
  value = aws_dynamodb_table.wallets.name
}

output "transactions_table_name" {
  value = aws_dynamodb_table.transactions.name
}

output "transactions_stream_arn" {
  value = aws_dynamodb_table.transactions.stream_arn
}

output "fraud_events_table_name" {
  value = aws_dynamodb_table.fraud_events.name
}
