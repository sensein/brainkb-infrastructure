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
  description = "Security group ID attached to the application host. Later slices (ALB) reference this."
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

# Structured output for the OpenTofu → PyInfra contract
# (implementation spec §11). The adapter reads this block via
# `tofu output -json pyinfra`.
output "pyinfra" {
  description = "Structured inventory intended for the PyInfra adapter (spec §11)."
  value = {
    environment = var.environment

    hosts = [{
      ssh_hostname = aws_instance.app.public_ip
      ssh_user     = var.ssh_user
    }]

    ui_port      = var.ui_port
    backend_port = var.backend_port

    # fsx_dns_name and fsx_mount_name are added by the Phase 5 storage
    # slice; they're absent here rather than null so the adapter can
    # unambiguously detect "storage not configured yet".
  }
}
