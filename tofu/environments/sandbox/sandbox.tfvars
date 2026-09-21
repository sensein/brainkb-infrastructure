# Sandbox environment values. Committed to git — must not contain
# secrets or personal operator IPs.

region = "us-east-2"

# The default VPC in the account, per discovery.md.
vpc_id = "vpc-056bce0f8a2a73bfe"

# All three default-VPC subnets (one per AZ). The EC2 lands in
# subnet_ids[0] — us-east-2a, matching production placement. The ALB
# slice will span all three for multi-AZ resilience.
subnet_ids = [
  "subnet-04b630da6d9b3674c", # us-east-2a — prod EC2 also here
  "subnet-0d82ab2916c10c979", # us-east-2b
  "subnet-01126225d35c86c11", # us-east-2c
]

# Small: sandbox does not need to match prod's c5.4xlarge. See
# discovery.md §Cost signal.
instance_type = "t3.medium"

# Reuses the existing EC2 key pair in the account (name is a leftover
# from another project per discovery.md; not blocking).
ssh_key_name = "rabbit-mq-server"

# Route 53 hosted zone for brainkb.org, per discovery.md.
hosted_zone_id = "Z06918342ADZVPCW09HXW"

# ssh_allowed_cidrs intentionally not set here — do it locally, via
# sandbox.auto.tfvars (gitignored) or TF_VAR_ssh_allowed_cidrs. See
# README.
