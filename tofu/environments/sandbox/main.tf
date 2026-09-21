module "brainkb" {
  source = "../../modules/brainkb"

  environment       = "sandbox"
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  instance_type     = var.instance_type
  ssh_key_name      = var.ssh_key_name
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  hosted_zone_id    = var.hosted_zone_id

  # Sandbox port convention: production port + 10000 (per the recent
  # sandbox commit that moved UI from 3080 → 13000). Keeps sandbox and
  # prod distinct when they cohabit an EC2 or share port maps.
  ui_port      = 13000
  backend_port = 18000

  alb_targets         = var.alb_targets
  dns_allow_overwrite = var.dns_allow_overwrite

  protect_persistent_data = false
}
