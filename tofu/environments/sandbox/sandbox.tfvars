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

# Sandbox ALB routing. Ports are production's own (not the +10000
# shift the co-tenant sandbox uses), since this is a separate instance.
# Hostnames are new test.* names (team decision, 2026-11-02), separate
# from the sandbox.* names the manually-built setup serves, so this
# stack never takes those over. Health check paths are
# "/" for the UI (Next.js will 200 on root) and TBD once each backend
# service confirms its /health endpoint — leaving as "/" (matches all
# non-empty responses of 200-299).
alb_targets = [
  {
    name              = "ui"
    hostname          = "test.brainkb.org"
    port              = 3000
    health_check_path = "/"
  },
  {
    name              = "usermgmt"
    hostname          = "usermanagement.test.brainkb.org"
    port              = 8004
    health_check_path = "/"
  },
  {
    name              = "mlservice"
    hostname          = "mlservice.test.brainkb.org"
    port              = 8007
    health_check_path = "/"
  },
  # query_service: the co-tenant sandbox (and production) reach it
  # directly on the host's IP and port. Here it goes behind the ALB like
  # the others (decisions.md §7's lean). Keep it last: listener-rule
  # priorities follow list order, so appending leaves the others alone.
  {
    name              = "queryservice"
    hostname          = "queryservice.test.brainkb.org"
    port              = 8010
    health_check_path = "/"
  },
]

# Publish the test.* hostnames as A-ALIAS records pointing at the ALB.
# Turned on 2026-11-02 once the apps were installed on the instance and
# all four hostnames answered through the ALB (UI and usermanagement
# 200, mlservice and queryservice 404 at "/"). Set back to false to
# take the names offline; the rest of the stack stays up.
create_app_dns_records = true

# False: tofu fails rather than replace a Route 53 record that already
# exists. The test.* names are new, so nothing should exist; if one
# does, that's a name clash to sort out by hand, not to overwrite.
# NEVER set true in production — import existing records instead.
dns_allow_overwrite = false

# FSx for Lustre + its own S3 bucket, like production (team decision,
# 2026-11-04: the test sandbox should match production's storage).
# Its own file system and bucket, not production's. PERSISTENT_2,
# 1.2 TB, 125 MB/s/TiB: about $175/month. pyinfra/deploy.py mounts it
# at /fsx and puts Oxigraph's data there.
enable_fsx = true
