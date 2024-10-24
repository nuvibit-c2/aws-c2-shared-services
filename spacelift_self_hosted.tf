# ---------------------------------------------------------------------------------------------------------------------
# ¦ DATA - SPACELIFT LOADBALANCER
# ---------------------------------------------------------------------------------------------------------------------
data "aws_lbs" "spacelift" {
  tags = {
    "platform" = "Spacelift"
  }
}

# spacelift self-hosted installation creates a loadbalancer
data "aws_lb" "spacelift" {
  arn = tolist(data.aws_lbs.spacelift.arns)[0]
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ ACM - CERTIFICATE & VALIDATION - SPACELIFT
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_acm_certificate" "spacelift" {
  domain_name       = module.ntc_r53_spacelift_nuvibit_dev.zone_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "spacelift" {
  for_each = {
    for dvo in aws_acm_certificate.spacelift.domain_validation_options : dvo.domain_name => {
      name    = dvo.resource_record_name
      record  = dvo.resource_record_value
      type    = dvo.resource_record_type
      zone_id = module.ntc_r53_spacelift_nuvibit_dev.zone_id
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = each.value.zone_id
}

# this resource waits for the certificate validation
resource "aws_acm_certificate_validation" "spacelift" {
  certificate_arn = aws_acm_certificate.spacelift.arn
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ NTC SPACELIFT ADMINISTRATION - WORKER POOL
# ---------------------------------------------------------------------------------------------------------------------
module "ntc_spacelift_administration" {
  source  = "spacelift.io/nuvibit/ntc-administration/spacelift"
  version = "1.0.0"

    private_worker_pools = [
    {
      pool_name        = "self-hosted-workers"
      pool_description = "spacelift self-hosted worker pool"
      space_path       = "/root"
      labels           = []
    }
  ]
}