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

## What this creates

Compute + ALB + DNS. Split by concern:

**Network reuse** — no new VPC/subnets. Uses the account's default VPC
and its three public subnets in us-east-2 (see `discovery.md`).

**Compute**

- `brainkb-sandbox-app` security group — no ingress by default. SSH
  ingress rules are added only when you supply `ssh_allowed_cidrs`;
  `0.0.0.0/0` is rejected by a validation rule. App-port ingress comes
  from the ALB SG (below), not `0.0.0.0/0`.
- `brainkb-sandbox-app` IAM role + instance profile with
  `AmazonSSMManagedInstanceCore` attached — lets you connect via SSM
  Session Manager without opening SSH.
- `brainkb-sandbox` EC2 instance — `t3.medium`, Ubuntu 22.04 LTS
  (auto-picks latest Canonical AMI), IMDSv2 required, 30 GB gp3
  encrypted root. Placed in `subnet-04b630da6d9b3674c` (us-east-2a).

**ALB + routing**

- `brainkb-sandbox-alb` security group — public 80/443 in; egress to
  the app SG on each target port only.
- `brainkb-sandbox-alb` — public Application Load Balancer, spans all
  three subnets (multi-AZ resilient by default).
- One target group per service (`brainkb-sandbox-ui`,
  `brainkb-sandbox-usermgmt`, `brainkb-sandbox-mlservice`), each with
  a `GET /` health check (matcher 200-299).
- HTTPS :443 listener with TLS 1.3 and a fixed-404 default action —
  unmatched hostnames don't accidentally route somewhere.
- One host-based listener rule per hostname; priorities start at 100.
- HTTP :80 listener that permanently redirects (301) to HTTPS.

**TLS + DNS**

- ACM certificate covering all three sandbox hostnames, DNS-validated
  through Route 53 automatically.
- A-ALIAS records in `brainkb.org` (zone `Z0691…`, per `discovery.md`)
  for `sandbox.brainkb.org`, `usermanagement.sandbox.brainkb.org`,
  and `mlservice.sandbox.brainkb.org`, pointing at the ALB.
- `dns_allow_overwrite = true` — sandbox has a stale
  `sandbox.brainkb.org` A record from an earlier attempt (per
  `sandbox/notes.md`); this flag lets tofu replace it in place. Never
  set true for production.

**Storage — deliberately off by default in sandbox**

- `enable_fsx = false` in `sandbox.tfvars`. No FSx filesystem, no S3
  data bucket. Oxigraph will use a plain Docker named volume on the
  EC2's EBS root, per `bootstrap.md` §Oxigraph.
- The module code for FSx + S3 exists (`storage.tf`) — flipping
  `enable_fsx = true` provisions:
  - S3 bucket `sensein-brainkb-sandbox-data` (versioned, encrypted,
    private) with `prevent_destroy` guarded by
    `protect_persistent_data`.
  - FSx SG allowing Lustre client protocol (988, 1018-1023) from the
    app SG only.
  - FSx for Lustre filesystem — `SCRATCH_2` by default (cheaper,
    single-AZ; production would flip to `PERSISTENT_2`), 1.2 TB, LZ4
    compression, in the same subnet as the EC2.
  - FSx ↔ S3 data-repository association with **conservative
    deletion policy** — imports/exports on NEW+CHANGED events only,
    not DELETED (per `decisions.md` §2).
- Cost signal: enabling FSx adds ~$100+/month for Lustre alone. Only
  worth it when we specifically want to test FSx-related PyInfra
  behavior before it goes into prod.

**Not yet in this environment** (own PRs, in order):

- PyInfra host configuration (Phase 4+)
- PyInfra app deployment (Phase 6-7)
- GitHub Actions automation (Phase 9)

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
    tofu output alb_dns_name
    tofu output app_hostnames
    tofu output -json pyinfra    # structured, for the PyInfra adapter

## Testing without waiting for DNS

Route 53 records propagate in seconds usually, but you can hit the ALB
directly before that by supplying the Host header:

    curl -k -H "Host: sandbox.brainkb.org" "https://$(tofu output -raw alb_dns_name)/"

`-k` skips TLS verification because the cert is for the sandbox
hostname, not the ALB's own AWS-generated name.

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
- **`tofu apply` hangs on the ACM cert.** DNS validation waits for
  the CNAME records to propagate and ACM to re-check. Usually a
  minute or two; can be up to five. Don't cancel — the next resource
  in the plan needs the validated cert.
- **`tofu apply` errors on target-group name length.** Target group
  names are `brainkb-sandbox-<name>` and AWS caps them at 32
  characters — keep each `alb_targets[*].name` under 16 chars.
- **Target group health checks fail.** Expected until the backend
  services are actually running on the EC2 (PyInfra slice, not yet
  implemented). The ALB creates fine; only the target-health readouts
  in the AWS console will be red until then.
