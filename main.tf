# ---------------------------------------------------------------------------------------------------------------------
# ¦ PROVIDER
# ---------------------------------------------------------------------------------------------------------------------
provider "aws" {
  region = "eu-central-1"
}

provider "aws" {
  alias  = "euc1"
  region = "eu-central-1"
}

provider "aws" {
  alias  = "euc2"
  region = "eu-central-2"
}

# provider for us-east-1 region is sometimes required for specific features or services
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

# provider "spacelift" {
#   api_key_endpoint = "https://spacelift.nuvibit.dev"
#   api_key_id       = "01JAZ0E21AXPEZEFCGP4SCCNN1"
#   api_key_secret   = var.spacelift_admin_token
# }

# ---------------------------------------------------------------------------------------------------------------------
# ¦ REQUIREMENTS
# ---------------------------------------------------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = []
    }
    # spacelift = {
    #   source  = "spacelift-io/spacelift"
    #   version = "~> 1.0"
    # }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ DATA
# ---------------------------------------------------------------------------------------------------------------------
data "aws_region" "default" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ LOCALS
# ---------------------------------------------------------------------------------------------------------------------
locals {}
