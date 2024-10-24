# ---------------------------------------------------------------------------------------------------------------------
# ¦ NTC ROUTE53 - PUBLIC HOSTED ZONE
# ---------------------------------------------------------------------------------------------------------------------
module "ntc_r53_spacelift_nuvibit_dev" {
  source  = "spacelift.io/nuvibit/ntc-route53/aws"
  version = "1.3.0"

  zone_force_destroy = false

  # name of the route53 hosted zone
  zone_name        = "spacelift.nuvibit.dev"
  zone_description = "Managed by Terraform"

  # private hosted zones require at least one vpc to be associated
  # public hosted zones cannot have any vpc associated
  zone_type = "public"

  # list of dns records which should be created in hosted zone. alias records are a special type of records
  # https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-choosing-alias-non-alias.html
  dns_records = [
    {
      # apex record for spacelift self-hosted loadbalancer - check 'spacelift_self_hosted.tf'
      name = ""
      type = "A"
      ttl  = 300
      alias = {
        enable_alias           = true
        target_dns_name        = data.aws_lb.spacelift.dns_name
        target_hosted_zone_id  = data.aws_lb.spacelift.zone_id
        evaluate_target_health = true
      }
    }
  ]

  providers = {
    aws = aws.euc1
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ NTC ROUTE53 - DNSSEC
# ---------------------------------------------------------------------------------------------------------------------
# WARNING: disabling DNSSEC before DS records expire can lead to domain becoming unavailable on the internet
# https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/dns-configuring-dnssec-disable.html
module "ntc_r53_spacelift_nuvibit_dev_dnssec" {
  source  = "spacelift.io/nuvibit/ntc-route53/aws//modules/dnssec"
  version = "1.3.0"

  zone_id = module.ntc_r53_spacelift_nuvibit_dev.zone_id

  # dnssec key can be rotated by creating a new 'inactive' key-signing-key and adding new DS records in root domain
  # WARNING: old key should stay active until new key-signing-key is provisioned and new DS records are propagated
  key_signing_keys = [
    {
      ksk_name   = "ksk-1"
      ksk_status = "active"
    }
  ]

  providers = {
    # dnssec requires the kms key to be in us-east-1
    aws.us_east_1 = aws.use1
  }
}
