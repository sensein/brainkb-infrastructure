# Sandbox environment values. Committed to git — must not contain
# secrets or personal operator IPs.

region = "us-east-2"

# The default VPC in the account, per discovery.md.
vpc_id = "vpc-056bce0f8a2a73bfe"

# All three default-VPC subnets (one per AZ). The EC2 lands in
# subnet_ids[0] — us-east-2a, matching production placement. The ALB
# spans all three for multi-AZ resilience.
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

# Sandbox ALB routing. Ports match the sandbox +10000 convention;
# hostnames mirror the sandbox/notes.md target. Health check paths are
# "/" for the UI (Next.js will 200 on root) and TBD once each backend
# service confirms its /health endpoint — leaving as "/" (matches all
# non-empty responses of 200-299).
alb_targets = [
  {
    name              = "ui"
    hostname          = "sandbox.brainkb.org"
    port              = 13000
    health_check_path = "/"
  },
  {
    name              = "usermgmt"
    hostname          = "usermanagement.sandbox.brainkb.org"
    port              = 18004
    health_check_path = "/"
  },
  {
    name              = "mlservice"
    hostname          = "mlservice.sandbox.brainkb.org"
    port              = 18007
    health_check_path = "/"
  },
]

# sandbox.brainkb.org (and the two subdomains) already have live
# Route 53 aliases pointing at the manually-built sandbox-alb (per
# sandbox/notes.md step 7b). This flag lets tofu take those records
# over and re-point them at the tofu-managed ALB. NEVER set true in
# production — production records should be imported into state
# before apply.
dns_allow_overwrite = true

# Sandbox does not create FSx by default — bootstrap.md notes it's
# not needed for sandbox use, and Oxigraph will fall back to a Docker
# named volume when enable_fsx is false. Flipping to true adds an
# ~$100+/month Lustre bill; only worth it if we want sandbox to
# mirror production storage-wise (e.g., testing FSx-related PyInfra
# behavior before rolling it into prod).
enable_fsx = false
