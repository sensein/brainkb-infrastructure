# ACM certificate covering every alb_targets hostname, DNS-validated
# via Route 53. Created only when the caller didn't supply an existing
# ARN via var.acm_certificate_arn.
resource "aws_acm_certificate" "app" {
  count                     = var.acm_certificate_arn == null ? 1 : 0
  domain_name               = var.alb_targets[0].hostname
  subject_alternative_names = slice([for t in var.alb_targets : t.hostname], 1, length(var.alb_targets))
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.name}-app" })
}

# One DNS validation record per hostname on the cert. AWS returns
# duplicate validation records when the same hostname appears in both
# domain_name and SANs; the for_each on unique domain_name dedupes.
resource "aws_route53_record" "cert_validation" {
  for_each = var.acm_certificate_arn == null ? {
    for dvo in aws_acm_certificate.app[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = var.dns_allow_overwrite
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.hosted_zone_id
}

resource "aws_acm_certificate_validation" "app" {
  count                   = var.acm_certificate_arn == null ? 1 : 0
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# Per-hostname A-ALIAS records pointing at the ALB.
resource "aws_route53_record" "app" {
  for_each = { for t in var.alb_targets : t.hostname => t }

  allow_overwrite = var.dns_allow_overwrite
  zone_id         = var.hosted_zone_id
  name            = each.value.hostname
  type            = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = false
  }
}
