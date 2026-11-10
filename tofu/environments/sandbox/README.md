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

- ACM certificate covering all four sandbox hostnames, DNS-validated
  through Route 53 automatically.
- **Its own hostnames** (team decision, 2026-11-02):
  `test.brainkb.org`, `usermanagement.test.brainkb.org`,
  `mlservice.test.brainkb.org` and `queryservice.test.brainkb.org`
  (query_service sits behind the ALB here, unlike production and the
  co-tenant sandbox, which reach it on the host's IP and port). The existing `sandbox.brainkb.org`
  names stay on the manually-built `sandbox-alb` and are never touched
  by this stack.
- **Published**: `create_app_dns_records = true` in `sandbox.tfvars`
  (since 2026-11-02), so tofu writes A-ALIAS records in `brainkb.org`
  (zone `Z0691…`, per `discovery.md`) pointing each `test.*` name at
  the new ALB. Setting it back to `false` removes just those records.
  While it was off, the stack was tested through the ALB's own address
  (see "Testing the new stack" below).
- `dns_allow_overwrite = false`: if a `test.*` record (or a cert
  validation record) already exists, apply fails instead of replacing
  it. Check first with `dig +short test.brainkb.org`; empty output
  means the name is free.
- The apps' own config has to use the `test.*` URLs too (for example
  `NEXTAUTH_URL` and the OAuth callback registered with the login
  provider). That's set when the services are deployed, not here: see
  `sandbox/new-server-setup.md` for installing the apps on this server.

**Storage — FSx for Lustre + S3, like production**

`enable_fsx = true` in `sandbox.tfvars` (team decision, 2026-11-04, so
the test sandbox matches production's storage). It's the sandbox's own
file system and bucket, separate from production's. It provisions:

- S3 bucket `sensein-brainkb-sandbox-data` (versioned, encrypted,
  private).
- FSx for Lustre, `PERSISTENT_2`, 1.2 TB, 125 MB/s/TiB, LZ4
  compression, in the same subnet as the EC2.
- The FSx ↔ S3 data-repository association: imports/exports on
  NEW+CHANGED events only, not DELETED, so deleting a file on one side
  doesn't delete it on the other. It needs `PERSISTENT_2`; `SCRATCH_2`
  doesn't support it.
- A lifecycle rule on the bucket: old versions of a file are deleted
  after 30 days, and unfinished uploads after 7. Versioning, not the
  missing DELETED event, is what protects against a bad write such as a
  wrong SPARQL DELETE: S3 keeps the earlier versions for those 30 days.
- FSx security group: Lustre ports (988, 1018-1023) between the file
  servers and with the app host, in both directions. The app SG gets
  the matching inbound rules from FSx.
- The bucket, file system and association all carry
  `prevent_destroy = true`.

Cost: about $175/month for the file system, plus S3 storage.
`pyinfra/deploy.py` installs the Lustre client, mounts the file system
at `/fsx`, and writes a nightly export of the graph store to
`/fsx/backups/`. Oxigraph's live data stays on the instance's own disk.

**Not yet in this environment** (own PRs, in order):

- PyInfra host configuration
- PyInfra app deployment
- GitHub Actions automation for `tofu` + PyInfra runs

## How to run

    cd tofu/environments/sandbox

    tofu init -backend-config=backend.hcl
    tofu plan  -var-file=sandbox.tfvars
    tofu apply -var-file=sandbox.tfvars

`tofu init` downloads the AWS provider and configures the S3
backend. Rerun it any time `versions.tf` or `backend.hcl` changes.

## Host access

`ssh_allowed_cidrs` defaults to `[]` — no SSH allowed to the world.
This is deliberate: `decisions.md` §5 (SSH/SSM) calls out that
opening `:22` broadly is not an acceptable shortcut, especially not
for CI. Three ways to reach the instance:

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

## Testing the new stack

Before the `test.*` names are published, reach the new ALB directly
and tell it which hostname you mean with a Host header:

    curl -k -H "Host: test.brainkb.org" "https://$(tofu output -raw alb_dns_name)/"

`-k` skips TLS verification because the cert is for `test.brainkb.org`,
not the ALB's own AWS-generated name.

## Destroy

    tofu destroy -var-file=sandbox.tfvars

A plain destroy stops at the S3 bucket, FSx file system and S3 link:
they're protected by `prevent_destroy = true` in
`modules/brainkb/storage.tf`. OpenTofu doesn't allow that to be a
variable, so to tear them down on purpose, change it to `false`
locally first (don't commit that). Check the bucket holds nothing you
need first: it's where the graph data is mirrored.

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
