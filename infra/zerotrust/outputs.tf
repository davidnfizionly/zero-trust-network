output "firewall_name" {
  value = aws_networkfirewall_firewall.zero_trust.name
}

output "firewall_endpoint_id" {
  value = local.firewall_endpoint_id
}

output "firewall_alert_log_group" {
  value = aws_cloudwatch_log_group.firewall_alert.name
}

output "vpc_flow_log_group" {
  value = aws_cloudwatch_log_group.vpc_flow.name
}

output "dynamodb_gateway_endpoint_id" {
  value = aws_vpc_endpoint.dynamodb.id
}

output "session_log_bucket" {
  value = aws_s3_bucket.session_logs.id
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.this.id
}

output "dynamodb_streams_endpoint_url" {
  value = "https://${aws_vpc_endpoint.interface["dynamodb-streams"].dns_entry[0].dns_name}"
}
