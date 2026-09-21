variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "vpc_id" {
  description = "VPC to place sandbox resources in. Values live in sandbox.tfvars."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs. Values live in sandbox.tfvars."
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type for sandbox."
  type        = string
  default     = "t3.medium"
}

variable "ssh_key_name" {
  description = "EC2 key pair name. Value in sandbox.tfvars."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "Operator IPs allowed to SSH. Leave empty here and set via a local sandbox.auto.tfvars (gitignored) or TF_VAR_ssh_allowed_cidrs env var — never commit personal IPs."
  type        = list(string)
  default     = []
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for brainkb.org. Value in sandbox.tfvars."
  type        = string
}
