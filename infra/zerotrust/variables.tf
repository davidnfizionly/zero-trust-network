variable "aws_region" {
  description = "AWS region of the baseline workload"
  type        = string
  default     = "us-east-1"
}

variable "workload_name" {
  description = "Name prefix of the baseline workload resources"
  type        = string
  default     = "payment-platform"
}

variable "firewall_subnet_cidr" {
  description = "CIDR of the firewall subnet (free range of the baseline VPC)"
  type        = string
  default     = "10.0.30.0/28"
}

variable "egress_allowed_domains" {
  description = "Domains the VPC may reach on TLS port 443 through the NAT gateway. Everything else is dropped and logged"
  type        = list(string)
  default = [
    # Istio images (istioctl demo profile pulls from Docker Hub)
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
  ]
}

variable "log_retention_days" {
  description = "Retention of the firewall, flow and session log groups"
  type        = number
  default     = 3
}
