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

  # Always protected: OpenTofu requires a literal here, so this can't
  # be toggled per environment. To deliberately tear down a sandbox
  # that enabled FSx, flip this to false locally first.
  lifecycle {
    prevent_destroy = true
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

# FSx security group. Lustre needs its ports (988, 1018-1023) open in
# both directions between the file servers and their clients, and among
# the file servers themselves; FSx refuses to create the file system
# without the self-referencing rules.
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

locals {
  lustre_ports = {
    "988"       = { from = 988, to = 988 }
    "1018-1023" = { from = 1018, to = 1023 }
  }
}

resource "aws_vpc_security_group_ingress_rule" "fsx_from_self" {
  for_each = var.enable_fsx ? local.lustre_ports : {}

  security_group_id            = aws_security_group.fsx[0].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.from
  to_port                      = each.value.to
  referenced_security_group_id = aws_security_group.fsx[0].id
  description                  = "Lustre (${each.key}) between FSx file servers"
  tags                         = local.tags
}

resource "aws_vpc_security_group_egress_rule" "fsx_to_self" {
  for_each = var.enable_fsx ? local.lustre_ports : {}

  security_group_id            = aws_security_group.fsx[0].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.from
  to_port                      = each.value.to
  referenced_security_group_id = aws_security_group.fsx[0].id
  description                  = "Lustre (${each.key}) between FSx file servers"
  tags                         = local.tags
}

resource "aws_vpc_security_group_egress_rule" "fsx_to_app" {
  for_each = var.enable_fsx ? local.lustre_ports : {}

  security_group_id            = aws_security_group.fsx[0].id
  ip_protocol                  = "tcp"
  from_port                    = each.value.from
  to_port                      = each.value.to
  referenced_security_group_id = aws_security_group.app.id
  description                  = "Lustre (${each.key}) to the app host"
  tags                         = local.tags
}

# The app SG's "all egress" rule covers client-to-server traffic; this is
# the server-to-client direction (production's SG has the same pair).
resource "aws_vpc_security_group_ingress_rule" "app_from_fsx" {
  for_each = var.enable_fsx ? local.lustre_ports : {}

  security_group_id            = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.from
  to_port                      = each.value.to
  referenced_security_group_id = aws_security_group.fsx[0].id
  description                  = "Lustre (${each.key}) from FSx"
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

  # Always protected — see aws_s3_bucket.data above.
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.name}-fsx" })
}

# The S3 mirror. Deletion propagation is intentionally conservative
# (import/export events omit DELETED) — see decisions.md §2. Data
# repository associations need a PERSISTENT_2 file system.
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

  # Always protected — see aws_s3_bucket.data above.
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.tags, { Name = "${local.name}-fsx-s3" })
}
