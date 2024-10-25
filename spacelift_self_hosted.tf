# ---------------------------------------------------------------------------------------------------------------------
# ¦ DATA
# ---------------------------------------------------------------------------------------------------------------------
# vpc was created by spacelift installation (custom vpc is also supported)
data "aws_vpcs" "spacelift_vpcs" {
  tags = {
    platform = "Spacelift"
  }
}

data "aws_vpc" "spacelift_vpc" {
  id = tolist(data.aws_vpcs.spacelift_vpcs.ids)[0]
}

data "aws_subnets" "spacelift_private_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.spacelift_vpc.id]
  }

  filter {
    name   = "tag:Name"
    values = [
      "Spacelift PrivateSubnet1",
      "Spacelift PrivateSubnet2",
      "Spacelift PrivateSubnet3",
    ]
  }
}

data "aws_subnet" "spacelift_private_subnet" {
  for_each = toset(data.aws_subnets.spacelift_private_subnets.ids)
  id       = each.value
}

# spacelift self-hosted installation creates a loadbalancer
data "aws_lbs" "spacelift_albs" {
  tags = {
    platform = "Spacelift"
  }
}

data "aws_lb" "spacelift_alb" {
  arn = tolist(data.aws_lbs.spacelift_albs.arns)[0]
}

# get latest spacelift ami
data "aws_ami" "spacelift" {
  most_recent = true
  name_regex  = "^spacelift-\\d{10}-x86_64$"
  owners      = ["643313122712"]

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
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
# ¦ NTC SPACELIFT ADMINISTRATION
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

# ---------------------------------------------------------------------------------------------------------------------
# ¦ SPACELIFT PRIVATE RUNNERS - CREDENTIALS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "spacelift_credentials" {
  for_each = toset(["SPACELIFT_TOKEN", "SPACELIFT_POOL_PRIVATE_KEY"])

  name = each.key
}

data "aws_iam_policy_document" "spacelift_credentials" {
  statement {
    sid    = "AllowInstanceRoleToReadSecret"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [module.spacelift_private_workers.instances_role_arn[0]]
    }

    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for secret in aws_secretsmanager_secret.spacelift_credentials : secret.arn]
  }
}

resource "aws_secretsmanager_secret_policy" "spacelift_credentials" {
  for_each = toset(["SPACELIFT_TOKEN", "SPACELIFT_POOL_PRIVATE_KEY"])

  secret_arn = aws_secretsmanager_secret.spacelift_credentials[each.key].arn
  policy     = data.aws_iam_policy_document.spacelift_credentials.json
}

resource "aws_secretsmanager_secret_version" "spacelift_credentials" {
  for_each = toset(["SPACELIFT_TOKEN", "SPACELIFT_POOL_PRIVATE_KEY"])

  secret_id     = aws_secretsmanager_secret.spacelift_credentials[each.key].id
  secret_string = module.ntc_spacelift_administration.private_worker_credentials_by_pool_name["self-hosted-workers"][each.key]
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ SPACELIFT PRIVATE RUNNERS - ASG
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_security_group" "private_workers" {
  name        = "spacelift_private_workers"
  description = "Allow all outbound traffic"
  vpc_id      = data.aws_vpc.spacelift_vpc.id

  egress {
    description = "Allow internet egress traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    # trivy:ignore:avd-aws-0104 Reason: cicd runners require access to internet (outgoing)
    cidr_blocks = ["0.0.0.0/0"]
    # trivy:ignore:avd-aws-0104 Reason: cicd runners require access to internet (outgoing)
    ipv6_cidr_blocks = ["::/0"]
  }
}

# using forked module including a fix to deploy worker pool in an opt-in region
# https://github.com/spacelift-io/spacelift-worker-image/blob/main/aws/README.md
module "spacelift_private_workers" {
  source = "github.com/nuvibit/terraform-aws-spacelift-workerpool-on-ec2?ref=fix-opt-in-region"

  # configuration = <<-EOT
  #   export SPACELIFT_TOKEN=$(aws secretsmanager get-secret-value --secret-id "${aws_secretsmanager_secret.spacelift_credentials["SPACELIFT_TOKEN"].id}" --query SecretString --region eu-central-1 --output text)
  #   export SPACELIFT_POOL_PRIVATE_KEY=$(aws secretsmanager get-secret-value --secret-id "${aws_secretsmanager_secret.spacelift_credentials["SPACELIFT_POOL_PRIVATE_KEY"].id}" --query SecretString --region eu-central-1 --output text)
  #   export SPACELIFT_SENSITIVE_OUTPUT_UPLOAD_ENABLED=true
  # EOT

  configuration = ""

  # completely overwrite userdata to support spacelift self-hosted
  overwrite_userdata = templatefile("${path.module}/files/spacelift-userdata.sh", {
      AWS_REGION = "eu-central-1"
      BINARIES_BUCKET = "xxx"
      RunLauncherAsSpaceliftUser = true
      POWER_OFF_ON_ERROR = true
      SECRET_NAME = ""
      # optional settings
      HTTP_PROXY_CONFIG = ""
      HTTPS_PROXY_CONFIG = ""
      NO_PROXY_CONFIG = ""
      ADDITIONAL_ROOT_CAS_SECRET_NAME = ""
      ADDITIONAL_ROOT_CAS = ""
      CustomUserDataSecretName = ""
    }
  )

  ami_id                       = "ami-042c73b746c928478" # data.aws_ami.spacelift.id
  ec2_instance_type            = "t3.small"
  volume_encryption            = true
  volume_encryption_kms_key_id = null
  security_groups              = [aws_security_group.private_workers.id]
  vpc_subnets                  = [for subnet in data.aws_subnet.spacelift_private_subnet : subnet.id]
  create_iam_role              = true
  enable_monitoring            = true
  enable_autoscaling           = false
  min_size                     = 1
  max_size                     = 1
  worker_pool_id               = module.ntc_spacelift_administration.private_worker_pools_by_name["self-hosted-workers"]

  providers = {
    aws = aws.euc1
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ SPACELIFT PRIVATE RUNNERS - IAM - SECRETSMANAGER
# ---------------------------------------------------------------------------------------------------------------------
data "aws_iam_policy_document" "spacelift" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for secret in aws_secretsmanager_secret.spacelift_credentials : secret.arn]
  }
}

resource "aws_iam_policy" "spacelift" {
  name        = "secretsmanager-policy"
  description = "Grant permission to get secrets"
  policy      = data.aws_iam_policy_document.spacelift.json
}

resource "aws_iam_role_policy_attachment" "spacelift" {
  role       = module.spacelift_private_workers.instances_role_name[0]
  policy_arn = aws_iam_policy.spacelift.arn
}