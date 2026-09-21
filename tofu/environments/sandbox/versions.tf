terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — bucket + lock table come from bootstrap/state/.
  # Configured via `tofu init -backend-config=backend.hcl` (see README).
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "brainkb"
      Environment = "sandbox"
      ManagedBy   = "opentofu"
    }
  }
}
