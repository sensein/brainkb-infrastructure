variable "region" {
  description = "AWS region for the state backend resources. Should match where BrainKB itself is deployed."
  type        = string
  default     = "us-east-2"
}

variable "state_bucket_name" {
  description = "S3 bucket name for OpenTofu state files. Must be globally unique across all of AWS."
  type        = string
  default     = "sensein-brainkb-tofu-state"
}

variable "lock_table_name" {
  description = "DynamoDB table name for OpenTofu state locking."
  type        = string
  default     = "sensein-brainkb-tofu-locks"
}
