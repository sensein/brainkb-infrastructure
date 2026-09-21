# BrainKB production infrastructure — discovery

Snapshot of the AWS resources BrainKB production runs on, as of
2026-09-21. Populated from live `aws` CLI reads against account
`164409279158` in region `us-east-2`.

**This is an inventory doc, not a runbook or a decisions log.**

- `bootstrap.md` — human-readable runbook for one-time manual setup.
  Reference it for *how* things were done; reference this doc for
  *what exists*.
- `decisions.md` — open questions with what's answered and what isn't.
  Reference it for *why we're going where we're going*.
- This file — the raw values in AWS today.

## AWS account and region

- **Account ID**: `164409279158`
- **Primary region**: `us-east-2` (Ohio)

## VPC

- **VPC ID**: `vpc-056bce0f8a2a73bfe`
- **Type**: default VPC (CIDR in `172.31.0.0/16` — characteristic of
  default VPCs).
- Both sandbox and production compute live here.

### Subnets

- **Production EC2 sits in**: `subnet-04b630da6d9b3674c` (us-east-2a),
  public — the instance has a public IP.
- **All other subnets in this VPC**: *TBD.* Needed for multi-AZ ALB
  setup. Command:

      aws ec2 describe-subnets \
          --filters Name=vpc-id,Values=vpc-056bce0f8a2a73bfe \
          --region us-east-2

## EC2 instance

| Field | Value |
|---|---|
| Instance ID | `i-02f4d763f21e415f0` |
| Name tag | `BrainKB` |
| Instance type | `c5.4xlarge` (16 vCPU, 32 GB RAM) |
| AMI | `ami-0f5fcdfbd140e4ab7` |
| Root volume | `vol-0c92bca751c04c3a6` (EBS, single volume) |
| AZ | `us-east-2a` |
| Private IP | `172.31.15.33` |
| Public IP | `3.13.122.67` |
| SSH key pair | `rabbit-mq-server` (leftover name from another project) |
| IAM instance profile | **none attached** |
| IMDSv2 | required |
| Launched | 2026-01-07 |

## Security groups

### `sg-00ae856ca219ae663` — `launch-wizard-25` (Name tag: `BrainKB-SG`)

The only SG attached to the production EC2. Auto-generated name from
the AWS "launch instance" wizard. Inbound rules:

| Port | Source | Purpose (from SG description) |
|---|---|---|
| 22 | `0.0.0.0/0` | SSH |
| 443 | `0.0.0.0/0` | HTTPS (ALB traffic) |
| 3000 | `0.0.0.0/0` | UI (Next.js/PM2) |
| 5051 | `0.0.0.0/0` | pgAdmin |
| 7878 | `0.0.0.0/0` | Oxigraph |
| 8000 | `0.0.0.0/0` | api token manager |
| 8004 | `0.0.0.0/0` | usermanagement (OAuth callback) |
| 8007 | `0.0.0.0/0` | ml_service / structsense |
| 8010 | `0.0.0.0/0` | query_service |
| 8080 | `0.0.0.0/0` | mcp |
| 988, 1018–1023 | `sg-09898d5bd183b7f15` | Lustre client protocol |
| 13000 | `sg-02e6912482926898b` | sandbox UI |
| 18004 | `sg-02e6912482926898b` | sandbox usermanagement |
| 18007 | `sg-02e6912482926898b` | sandbox ml_service |

Egress: default all-traffic to `0.0.0.0/0`, plus a redundant explicit
outbound to port 8004.

### `sg-09898d5bd183b7f15` — FSx Lustre security group

Referenced from the EC2 SG for FSx client protocol (ports 988,
1018–1023). Attached to the FSx filesystem itself. Full rules TBD.

### `sg-02e6912482926898b` — sandbox security group

Referenced by three inbound rules on the EC2 SG (ports 13000, 18004,
18007). What this SG is *attached to* is TBD — it will clarify whether
sandbox compute exists or is still notional. Command:

    aws ec2 describe-network-interfaces \
        --filters Name=group-id,Values=sg-02e6912482926898b \
        --region us-east-2

## IAM

- **No IAM role attached to the production EC2 instance.**
- Any current AWS API access from the instance uses static credentials
  or nothing at all.
- Attaching an instance profile is the natural first step when we
  adopt SSM / Secrets Manager (decisions.md §5, §8).

## Route 53

Both public hosted zones in this account:

| Zone | Zone ID | Records | Notes |
|---|---|---|---|
| `brainkb.org.` | `Z06918342ADZVPCW09HXW` | 25 | The one we manage; holds the 4 confirmed-live subdomains from `bootstrap.md` (`beta.`, `usermanagement.`, `mlservice.`, `mcp.`) plus ACM validation records and the stale `sandbox.brainkb.org` A record noted in `sandbox/notes.md`. |
| `bican-kb.com.` | `Z05781153K6JB7XXSHR1O` | 4 | Related BICAN project domain; not part of this BrainKB inventory. |

For sandbox: new records under `Z06918342ADZVPCW09HXW` (ALIAS records
pointing at the sandbox ALB — replacing the stale `sandbox.` A record).

## Storage — FSx + S3

Partially known:

- **Filesystem type**: FSx for Lustre (per Tek).
- **Backing S3 bucket**: linked via FSx data-repository association.
  Also serves as the current backup path (per Tek).
- **Security group**: `sg-09898d5bd183b7f15`.
- **Mount point on host**: `/fsx/brainkb-kg-repo` (per `bootstrap.md`).
  Contains Oxigraph's data.

TBD via `aws fsx describe-file-systems`: filesystem ID, throughput
mode, deployment type, capacity, S3 sync direction, linked bucket
name.

## ALB inventory

TBD. `bootstrap.md` describes three separate production ALBs (one per
domain: `beta.`, `usermanagement.`, `mlservice.`) — dig-verified via
distinct IP sets. `sandbox/notes.md` targets a single ALB with
host-based routing (the opposite pattern), which is also the target
architecture for prod eventually. Command:

    aws elbv2 describe-load-balancers --region us-east-2
    aws elbv2 describe-target-groups --region us-east-2
    aws elbv2 describe-listeners --load-balancer-arn <each ALB ARN>

## Application deployment (reference)

Not repeated here — see `bootstrap.md` for the current process,
in particular:

- Backend runs in Docker, launched via `BrainKB/start_service.sh`.
- UI runs directly on the host under PM2, via
  `brainkb-ui/bin/up-node.sh`.
- Ollama runs outside Docker Compose via raw `docker run` with
  GPU-auto-detect (CPU-only in current prod, per Tek).
- `chat_service` is not currently deployed.

## Environment variables and secrets (reference)

Not repeated here — see `production/backend.env.template` and
`production/ui.env.template` for the shapes. Real secrets flagged in
`bootstrap.md` §Credentials for the two known-exposed values that
need rotation.

## Notable observations

Things that stood out during discovery. Fold-in candidates for
`decisions.md` or immediate hardening work — not decisions
themselves.

### Security posture

- **SSH port 22 is open to `0.0.0.0/0`.** Predates any CI ambition;
  matches decisions.md §5's warning about not widening `:22` for CI.
- **pgAdmin (port 5051) is publicly reachable.** Database admin UI
  on the open internet.
- **Oxigraph HTTP (port 7878) is publicly reachable.** Depending on
  SPARQL auth, either intentional read access or an unintentional
  write vector.
- **Every application port is `0.0.0.0/0`** — 3000, 8000, 8004,
  8007, 8010, 8080. The ALB in front of these services is
  effectively cosmetic today; direct-port access bypasses HTTPS,
  domains, and any ALB-enforced routing.

### Cost signal

- `c5.4xlarge` is roughly $0.60–0.70/hour on-demand → several
  hundred dollars per month for compute alone. Given the ~0.4% CPU
  utilization noted in `bootstrap.md`, this is not proportional to
  load. Not something to change today, but sandbox does not need to
  match — `t3.small` or `t3.medium` is a reasonable starting size,
  order of magnitude cheaper.

### Missing IAM role

- Attaching an instance profile is a prerequisite to using SSM /
  Secrets Manager / S3 role-based access cleanly. First natural step
  when we bring managed AWS services into the picture.

### Sandbox exists in a partial state

- SG `sg-02e6912482926898b` exists and is referenced by three
  prod-EC2 rules (sandbox UI + two sandbox services). What it's
  attached to is TBD — clarifies whether sandbox compute is standing
  up or still on paper.

## Data gaps

In priority order for what unblocks the next work:

1. **Other subnets in `vpc-056bce0f8a2a73bfe`** — blocks sandbox ALB
   (needs 2+ AZs).
2. **ALB inventory** — needed for prod-import (Phase 10), not sandbox
   greenfield.
3. **FSx filesystem details** — needed for Phase 5 storage
   codification.
4. **Sandbox SG attachment** — clarifies sandbox's current state.
5. **S3 bucket inventory** — the FSx-linked bucket, plus any others.

## Provenance

Values in this doc came from these `aws` CLI reads on 2026-09-16
through 2026-09-21 in AWS CloudShell, us-east-2:

- `ec2 describe-instances --instance-ids i-02f4d763f21e415f0`
- `ec2 describe-security-groups --group-ids sg-00ae856ca219ae663`
- `route53 list-hosted-zones`

Re-run any of them to refresh; this file is a point-in-time snapshot,
not a live source of truth.
