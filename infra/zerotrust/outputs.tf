output "firewall_endpoint_id" {
  value = local.firewall_endpoint_id
}

output "dynamodb_streams_endpoint_url" {
  description = "Explicit endpoint for the fraud-detection stream reader (the service has no private DNS name)"
  value       = "https://${aws_vpc_endpoint.interface["dynamodb-streams"].dns_entry[0].dns_name}"
}

output "log_groups" {
  value = {
    firewall_alert  = aws_cloudwatch_log_group.firewall_alert.name
    firewall_flow   = aws_cloudwatch_log_group.firewall_flow.name
    vpc_flow        = aws_cloudwatch_log_group.flow.name
    session_manager = aws_cloudwatch_log_group.sessions.name
  }
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.this.id
}
