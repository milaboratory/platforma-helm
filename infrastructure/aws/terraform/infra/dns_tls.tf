# =============================================================================
# ACM certificate (DNS-validated via Route53)
# =============================================================================
# Mirrors cloudformation-eks-1-35.yaml Certificate. The ALB ingress (configured
# by the platforma module) terminates TLS with this cert. CF lets CloudFormation
# auto-create the Route53 validation records via DomainValidationOptions; the
# idiomatic Terraform equivalent is an explicit aws_route53_record +
# aws_acm_certificate_validation, which also lets `terraform apply` block until
# the cert is ISSUED.
#
# Gated on ingress_enabled — with ingress off there is no TLS endpoint to certify
# (infra-only smoke tests). domain_name and route53_zone_id are then unused.
# =============================================================================

resource "aws_acm_certificate" "this" {
  count = var.ingress_enabled ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = { Name = "${var.cluster_name}-certificate" }

  lifecycle {
    create_before_destroy = true
  }
}

# Single domain, no SANs → exactly one validation record. Use count (known at
# plan from ingress_enabled) rather than for_each over domain_validation_options,
# whose keys are computed and unknown until the cert is created.
resource "aws_route53_record" "cert_validation" {
  count = var.ingress_enabled ? 1 : 0

  zone_id         = var.route53_zone_id
  name            = tolist(aws_acm_certificate.this[0].domain_validation_options)[0].resource_record_name
  type            = tolist(aws_acm_certificate.this[0].domain_validation_options)[0].resource_record_type
  records         = [tolist(aws_acm_certificate.this[0].domain_validation_options)[0].resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = var.ingress_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = aws_route53_record.cert_validation[*].fqdn
}
