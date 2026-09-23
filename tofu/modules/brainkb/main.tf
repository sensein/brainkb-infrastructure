data "aws_ami" "ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    # Match both the standard (hvm-ssd) and gp3-tagged (hvm-ssd-gp3)
    # AMI families. Canonical doesn't publish the gp3-tagged variant
    # for every region+release combination (jammy in us-east-2 has
    # only the hvm-ssd family right now). The root volume gets
    # converted to gp3 by compute.tf's root_block_device regardless.
    values = ["ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name   = "brainkb-${var.environment}"
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id

  # Cert ARN used by the HTTPS listener: caller-supplied when provided,
  # otherwise the one this module created and validated in dns.tf.
  certificate_arn = var.acm_certificate_arn != null ? var.acm_certificate_arn : aws_acm_certificate_validation.app[0].certificate_arn

  tags = {
    Environment = var.environment
    ManagedBy   = "opentofu"
  }
}
