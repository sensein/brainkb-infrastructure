output "instance_id" {
  description = "Sandbox EC2 instance ID."
  value       = module.brainkb.instance_id
}

output "instance_public_ip" {
  description = "Sandbox EC2 public IP."
  value       = module.brainkb.instance_public_ip
}

output "instance_private_ip" {
  description = "Sandbox EC2 private IP."
  value       = module.brainkb.instance_private_ip
}

output "pyinfra" {
  description = "Structured inventory for the PyInfra adapter. Read via `tofu output -json pyinfra`."
  value       = module.brainkb.pyinfra
}

output "alb_dns_name" {
  description = "ALB DNS name — useful for testing before Route 53 records propagate (e.g., curl with -H \"Host: sandbox.brainkb.org\")."
  value       = module.brainkb.alb_dns_name
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate covering the sandbox hostnames."
  value       = module.brainkb.acm_certificate_arn
}

output "app_hostnames" {
  description = "Hostnames that route to sandbox via the ALB."
  value       = module.brainkb.app_hostnames
}

output "fsx_dns_name" {
  description = "FSx for Lustre DNS name — null when enable_fsx=false (the sandbox default)."
  value       = module.brainkb.fsx_dns_name
}

output "data_bucket_name" {
  description = "S3 data-bucket name backing FSx — null when enable_fsx=false."
  value       = module.brainkb.data_bucket_name
}
