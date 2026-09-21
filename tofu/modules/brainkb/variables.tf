variable "environment" {
  description = "Environment name (e.g., \"sandbox\", \"production\"). Used in resource names and tags."
  type        = string
}

variable "vpc_id" {
  description = "ID of an existing VPC to place resources in. v1 reuses the account's default VPC; a dedicated VPC is a v2 direction (implementation spec §7)."
  type        = string
}

variable "subnet_ids" {
  description = "Existing subnet IDs. Must cover at least two AZs once an ALB is added; the EC2 lands in subnet_ids[0]."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet is required."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the BrainKB host."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "Explicit AMI ID. If null, the module looks up the latest Ubuntu 22.04 LTS (Canonical, hvm-ssd-gp3, amd64)."
  type        = string
  default     = null
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair used for SSH access. Confirmed present in the account per discovery.md (e.g., \"rabbit-mq-server\")."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed inbound to port 22. Empty by default — SSM Session Manager is the recommended access path (decisions.md §5). Do NOT set to 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not an allowed value for ssh_allowed_cidrs. Use SSM Session Manager, a bastion, or a specific operator IP."
  }
}

variable "ssh_user" {
  description = "OS user for SSH login. Ubuntu AMIs default to \"ubuntu\"."
  type        = string
  default     = "ubuntu"
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for brainkb.org. Used by the ALB slice (dns.tf) once added."
  type        = string
}

variable "ui_port" {
  description = "Port the Next.js UI listens on."
  type        = number
  default     = 3000
}

variable "backend_port" {
  description = "Port the primary backend service listens on."
  type        = number
  default     = 8000
}

variable "root_volume_size_gb" {
  description = "Size of the EC2 root EBS volume in GB."
  type        = number
  default     = 30
}

variable "protect_persistent_data" {
  description = "If true, persistent resources (FSx, S3 data buckets — added in a later slice) get lifecycle prevent_destroy. Set true for production."
  type        = bool
  default     = false
}

variable "alb_targets" {
  description = "ALB routing targets. Each entry creates a target group + HTTPS listener rule that forwards its hostname to the given port on the EC2 host. At least one entry is required."
  type = list(object({
    name              = string
    hostname          = string
    port              = number
    health_check_path = optional(string, "/")
  }))

  validation {
    condition     = length(var.alb_targets) >= 1
    error_message = "At least one alb_targets entry is required."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of an existing ACM certificate covering all alb_targets hostnames. If null (default), the module creates one and DNS-validates it via Route 53."
  type        = string
  default     = null
}

variable "dns_allow_overwrite" {
  description = "If true, Route 53 records may replace existing records with the same name+type. Appropriate for sandbox where a known-stale record exists (see sandbox/notes.md); never set true for production — import existing records instead."
  type        = bool
  default     = false
}
