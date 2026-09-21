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
