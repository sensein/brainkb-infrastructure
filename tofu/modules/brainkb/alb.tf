resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "BrainKB ${var.environment} ALB. Public 80/443 ingress; egress to the app SG on each target port only."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS from anywhere"
  tags              = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP (redirected to HTTPS by the listener)"
  tags              = local.tags
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  for_each = { for t in var.alb_targets : t.name => t }

  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.app.id
  description                  = "To app on ${each.value.name}:${each.value.port}"
  tags                         = local.tags
}

# App SG ingress from ALB SG — one rule per target port. This is what
# replaces production's current pattern of app ports being open to
# 0.0.0.0/0 (see discovery.md).
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  for_each = { for t in var.alb_targets : t.name => t }

  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "${each.value.name} from ALB"
  tags                         = local.tags
}

resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids

  tags = merge(local.tags, { Name = "${local.name}-alb" })
}

resource "aws_lb_target_group" "app" {
  for_each = { for t in var.alb_targets : t.name => t }

  name        = "${local.name}-${each.value.name}"
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    path                = each.value.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-299"
  }

  tags = merge(local.tags, { Name = "${local.name}-${each.value.name}" })
}

resource "aws_lb_target_group_attachment" "app" {
  for_each = aws_lb_target_group.app

  target_group_arn = each.value.arn
  target_id        = aws_instance.app.id
  port             = each.value.port
}

# HTTPS listener. Default action is a fixed 404 so unmatched hostnames
# don't accidentally route somewhere — every serving hostname must have
# an explicit listener rule below.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found."
      status_code  = "404"
    }
  }

  tags = local.tags
}

# One listener rule per target hostname. Priorities start at 100 so
# there's room to insert higher-priority rules manually later.
resource "aws_lb_listener_rule" "host_based" {
  for_each = { for i, t in var.alb_targets : t.name => merge(t, { priority = 100 + i }) }

  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  condition {
    host_header {
      values = [each.value.hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[each.value.name].arn
  }

  tags = local.tags
}

# HTTP :80 → HTTPS :443 permanent redirect.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = local.tags
}
