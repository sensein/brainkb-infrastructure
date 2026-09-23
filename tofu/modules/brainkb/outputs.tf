output "instance_id" {
  description = "EC2 instance ID for the BrainKB host."
  value       = aws_instance.app.id
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance (present because the subnet auto-assigns; see discovery.md)."
  value       = aws_instance.app.public_ip
}

output "instance_private_ip" {
  description = "Private IP of the EC2 instance."
  value       = aws_instance.app.private_ip
}

output "app_security_group_id" {
  description = "Security group ID attached to the application host. The ALB SG (alb.tf) references it as its ingress source."
  value       = aws_security_group.app.id
}

output "iam_role_name" {
  description = "IAM role attached to the application host."
  value       = aws_iam_role.app.name
}

output "alb_dns_name" {
  description = "ALB's public DNS name — useful for testing before Route 53 records propagate."
  value       = aws_lb.app.dns_name
}

output "alb_zone_id" {
  description = "Route 53 zone ID of the ALB itself (not the hosted zone). Needed to construct additional ALIAS records that point here."
  value       = aws_lb.app.zone_id
}

output "alb_arn" {
  description = "ARN of the ALB."
  value       = aws_lb.app.arn
}

output "alb_security_group_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "acm_certificate_arn" {
  description = "ARN of the ACM certificate the ALB uses — either the module-managed one or the caller-supplied one."
  value       = local.certificate_arn
}

output "app_hostnames" {
  description = "Hostnames that route to the app via the ALB."
  value       = [for t in var.alb_targets : t.hostname]
}

output "fsx_dns_name" {
  description = "FSx for Lustre DNS name — null when enable_fsx is false."
  value       = var.enable_fsx ? aws_fsx_lustre_file_system.data[0].dns_name : null
}

output "fsx_mount_name" {
  description = "FSx for Lustre mount name — null when enable_fsx is false."
  value       = var.enable_fsx ? aws_fsx_lustre_file_system.data[0].mount_name : null
}

output "data_bucket_name" {
  description = "S3 data-bucket name backing FSx — null when enable_fsx is false."
  value       = var.enable_fsx ? aws_s3_bucket.data[0].id : null
}

# Structured output for the OpenTofu → PyInfra contract. The adapter
# reads this block via `tofu output -json pyinfra`. fsx_* fields are
# null when FSx isn't provisioned so the adapter can fall back to a
# Docker named volume.
output "pyinfra" {
  description = "Structured inventory intended for the PyInfra adapter: environment, hosts[], ui_port, backend_port, and fsx_* (null when enable_fsx=false)."
  value = {
    environment = var.environment

    hosts = [{
      ssh_hostname = aws_instance.app.public_ip
      ssh_user     = var.ssh_user
    }]

    ui_port      = var.ui_port
    backend_port = var.backend_port

    fsx_dns_name   = var.enable_fsx ? aws_fsx_lustre_file_system.data[0].dns_name : null
    fsx_mount_name = var.enable_fsx ? aws_fsx_lustre_file_system.data[0].mount_name : null
  }
}
