# Persistent plane: S3 bucket + FSx for Lustre + data-repository
# association. Gated by var.enable_fsx (default off — sandbox uses a
# Docker named volume for Oxigraph when disabled, per bootstrap.md
# §Oxigraph storage). Production sets true.

locals {
  data_bucket = var.data_bucket_name != null ? var.data_bucket_name : "sensein-${local.name}-data"
}

resource "aws_s3_bucket" "data" {
  count = var.enable_fsx ? 1 : 0

  bucket = local.data_bucket

  lifecycle {
    prevent_destroy = var.protect_persistent_data
  }

  tags = merge(local.tags, { Name = local.data_bucket })
}

resource "aws_s3_bucket_versioning" "data" {
  count = var.enable_fsx ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  count = var.enable_fsx ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  count = var.enable_fsx ? 1 : 0

  bucket = aws_s3_bucket.data[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FSx security group — Lustre client protocol from the app SG only.
# App SG's existing "all egress" rule already permits outbound to
# FSx; no reverse rules needed here.
resource "aws_security_group" "fsx" {
  count = var.enable_fsx ? 1 : 0

  name        = "${local.name}-fsx"
  description = "BrainKB ${var.environment} FSx for Lustre. Client protocol from the app SG only."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name}-fsx" })
}

resource "aws_vpc_security_group_ingress_rule" "fsx_from_app_988" {
  count = var.enable_fsx ? 1 : 0

  security_group_id            = aws_security_group.fsx[0].id
  ip_protocol                  = "tcp"
  from_port                    = 988
  to_port                      = 988
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Lustre client (988) from app SG"
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "fsx_from_app_1018_1023" {
  count = var.enable_fsx ? 1 : 0

  security_group_id            = aws_security_group.fsx[0].id
  ip_protocol                  = "tcp"
  from_port                    = 1018
  to_port                      = 1023
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Lustre client (1018-1023) from app SG"
  tags                         = local.tags
}

resource "aws_fsx_lustre_file_system" "data" {
  count = var.enable_fsx ? 1 : 0

  storage_capacity      = var.fsx_storage_capacity_gb
  deployment_type       = var.fsx_deployment_type
  subnet_ids            = [var.subnet_ids[0]] # Lustre is single-AZ
  security_group_ids    = [aws_security_group.fsx[0].id]
  data_compression_type = var.fsx_data_compression

  # per_unit_storage_throughput applies to PERSISTENT_* only.
  per_unit_storage_throughput = startswith(var.fsx_deployment_type, "PERSISTENT_") ? var.fsx_throughput_per_unit_storage : null

  lifecycle {
    prevent_destroy = var.protect_persistent_data
  }

  tags = merge(local.tags, { Name = "${local.name}-fsx" })
}

# The S3 mirror. Deletion propagation is intentionally conservative
# (import/export events omit DELETED) — see decisions.md §2.
resource "aws_fsx_data_repository_association" "data" {
  count = var.enable_fsx ? 1 : 0

  file_system_id       = aws_fsx_lustre_file_system.data[0].id
  data_repository_path = "s3://${aws_s3_bucket.data[0].id}/"
  file_system_path     = "/"

  s3 {
    auto_import_policy {
      events = var.fsx_s3_import_events
    }
    auto_export_policy {
      events = var.fsx_s3_export_events
    }
  }

  batch_import_meta_data_on_create = true

  lifecycle {
    prevent_destroy = var.protect_persistent_data
  }

  tags = merge(local.tags, { Name = "${local.name}-fsx-s3" })
}
