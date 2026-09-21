data "aws_ami" "ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name   = "brainkb-${var.environment}"
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id

  tags = {
    Environment = var.environment
    ManagedBy   = "opentofu"
  }
}
