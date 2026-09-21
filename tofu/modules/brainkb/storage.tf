# FSx for Lustre + S3 (persistent plane) — see decisions.md §1, §2.
#
# Not yet implemented. Sandbox v1 does not create FSx; per bootstrap.md
# §Oxigraph storage, sandbox can use a plain Docker named volume for
# Oxigraph data. FSx is production's persistent plane and will be
# added when we get to prod-import (spec Phase 10) or when sandbox
# needs to mirror prod exactly.
#
# When this slice lands (spec Phase 5) it will add:
# - aws_fsx_lustre_file_system.data
# - aws_s3_bucket.fsx_data with versioning
# - aws_fsx_data_repository_association.data
# - IAM permissions on aws_iam_role.app for reading/writing the bucket
# - protect_persistent_data lifecycle guard on the FSx + bucket
