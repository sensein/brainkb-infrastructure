output "state_bucket" {
  description = "S3 bucket holding OpenTofu state files. Reference from other environments' backend configs."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table used for OpenTofu state locking."
  value       = aws_dynamodb_table.locks.name
}

output "region" {
  description = "AWS region where the state backend lives."
  value       = var.region
}
