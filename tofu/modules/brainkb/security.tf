resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "BrainKB ${var.environment} application host. Ingress is scoped: SSH from operator CIDRs only; app ports from the ALB SG (added in the ALB slice)."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-app" })
}

resource "aws_vpc_security_group_ingress_rule" "app_ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.app.id
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
  description       = "SSH from operator IP ${each.value}"
  tags              = local.tags
}

resource "aws_vpc_security_group_egress_rule" "app_egress_all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound (package installs, image pulls, health check egress, etc.)"
  tags              = local.tags
}
