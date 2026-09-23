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

variable "alb_targets" {
  description = "ALB routing targets — see the brainkb module's alb_targets variable. Set in sandbox.tfvars."
  type = list(object({
    name              = string
    hostname          = string
    port              = number
    health_check_path = optional(string, "/")
  }))
}

variable "dns_allow_overwrite" {
  description = "If true, Route 53 records may replace existing records with the same name+type. True in sandbox so tofu can take over the sandbox.brainkb.org records already in place from the manual ALB setup (see sandbox/notes.md)."
  type        = bool
  default     = false
}

variable "enable_fsx" {
  description = "If true, sandbox provisions FSx for Lustre + a linked S3 bucket. Defaults to false — sandbox uses a Docker named volume per bootstrap.md."
  type        = bool
  default     = false
}
