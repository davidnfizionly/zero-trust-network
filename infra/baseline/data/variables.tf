variable "aws_region" {
  description = "AWS region for this project"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Workload name, used as the prefix for resource names"
  type        = string
  default     = "payment-platform"
}
