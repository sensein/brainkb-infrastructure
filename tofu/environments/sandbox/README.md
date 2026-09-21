# Sandbox environment

OpenTofu configuration for the BrainKB sandbox environment.

## Prerequisites

1. **OpenTofu ≥ 1.7** installed locally, or use AWS CloudShell.
2. **AWS credentials** for account `164409279158` with permission to
   create/read EC2, IAM, and use the state bucket + lock table.
3. **State backend must exist.** Run `bootstrap/state/` first — see
   its README. This environment stores state in
   `s3://sensein-brainkb-tofu-state/brainkb/sandbox/tofu.tfstate`,
   locked via the DynamoDB table created there.

## What this creates (v1 slice — compute only)

- **No new VPC/subnets** — reuses the account's default VPC and its
  three public subnets in us-east-2 (see `discovery.md`).
- **`brainkb-sandbox-app` security group** — empty ingress by default
  (SSM Session Manager is the intended access path). SSH ingress is
  added only when you supply `ssh_allowed_cidrs`; `0.0.0.0/0` is
  explicitly rejected by a validation rule.
- **`brainkb-sandbox-app` IAM role + instance profile** with
  `AmazonSSMManagedInstanceCore` attached — lets you connect via
  SSM Session Manager without opening SSH.
- **`brainkb-sandbox` EC2 instance** — `t3.medium`, Ubuntu 22.04 LTS
  (auto-selected latest Canonical AMI), IMDSv2 required, 30 GB gp3
  encrypted root. Placed in `subnet-04b630da6d9b3674c` (us-east-2a).

**Not yet in this slice** (each will be its own PR):

- ALB, target groups, listener rules
- Route 53 records for `sandbox.brainkb.org` etc.
- FSx for Lustre + S3 (sandbox uses a plain Docker volume for now)
- PyInfra host configuration (Phase 4+ from the implementation spec)

## How to run

    cd tofu/environments/sandbox

    tofu init -backend-config=backend.hcl
    tofu plan  -var-file=sandbox.tfvars
    tofu apply -var-file=sandbox.tfvars

`tofu init` downloads the AWS provider and configures the S3
backend. Rerun it any time `versions.tf` or `backend.hcl` changes.

## Host access

`ssh_allowed_cidrs` defaults to `[]` — no SSH allowed to the world.
This is deliberate: the implementation spec §20 and `decisions.md` §5
both call out that opening `:22` broadly is not an acceptable
shortcut. Three ways to reach the instance:

1. **SSM Session Manager (recommended, no config needed).** Once the
   instance is up, either:

       aws ssm start-session --target <instance-id> --region us-east-2

   or in the AWS Console: EC2 → Instances → your instance →
   **Connect** → **Session Manager** → **Connect**. Uses the IAM
   role's SSM access; no SSH port, no keys, every session logged in
   CloudTrail.

2. **SSH from your specific IP.** Create a local
   `sandbox.auto.tfvars` (gitignored):

       ssh_allowed_cidrs = ["YOUR.PUBLIC.IP.HERE/32"]

   Then `tofu apply` picks it up automatically. Never commit this
   file. Use `curl ifconfig.me` to find your current IP.

3. **Environment variable** (single-shot):

       export TF_VAR_ssh_allowed_cidrs='["YOUR.PUBLIC.IP.HERE/32"]'
       tofu apply -var-file=sandbox.tfvars

The instance's `ssh_key_name` is `rabbit-mq-server` (reused from
another project — noted in `discovery.md`, not blocking).

## Outputs

After apply, useful commands:

    tofu output instance_id
    tofu output instance_public_ip
    tofu output -json pyinfra    # structured, for the PyInfra adapter

## Destroy

    tofu destroy -var-file=sandbox.tfvars

Safe today because sandbox has no persistent data yet. Once the
storage slice lands, `protect_persistent_data = false` here still
allows destroy for sandbox (as intended); production will flip that
to `true`.

## Common issues

- **`tofu init` fails on backend init.** The state bucket doesn't
  exist yet; go run `bootstrap/state/` first.
- **`tofu plan` complains about `ssh_allowed_cidrs`.** You put
  `0.0.0.0/0` somewhere — remove it. Use SSM instead.
- **Session Manager says "Not Registered".** The instance needs to
  finish first-boot registration with SSM (a minute or two after
  `tofu apply` completes). Also verify the region is `us-east-2`.
