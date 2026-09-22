# BrainKB infrastructure — decisions

Open questions, choices, and design intent for BrainKB's
infrastructure. Sibling to:

- `discovery.md` — what exists in AWS today (raw values, no opinions).
- `bootstrap.md` — how one-time setup was done (runbook).
- This file — *why* we're going where we're going.

Anything forward-looking or opinion-based about the infrastructure
belongs here, not in `discovery.md`.

**Note on section numbering.** Other files in the repo cite this doc
by section number (e.g. `decisions.md §5`, `§1`, `§2`, `§8`) —
references that predate this file's current shape. Once the section
list below stabilizes, sweep the repo for `decisions.md §` and update
the citations to match.

## Sandbox and production compute — shared EC2 or separate?

**Status: open, blocked on Tek's input.**

Today "sandbox" is a set of processes co-tenanted on production's
`c5.4xlarge` (see `sandbox/README.md`, `sandbox/notes.md`) — separate
PM2 process, separate Docker network, +10000 port offset, but same
host, kernel, IAM role, and security group as prod.

Options:

- **Keep co-tenanting long-term.** Prod's `c5.4xlarge` runs at ~0.4%
  CPU per `bootstrap.md` — massively over-provisioned. A dedicated
  sandbox `t3.medium` adds ~$30/month for capacity we don't need. One
  host to patch, monitor, back up, and SSH into. Sandbox exercises the
  same kernel, network stack, FSx mount, and system quirks as prod.

  Tradeoffs: sandbox misbehavior (OOM, runaway ML jobs, memory leaks)
  can degrade or kill prod. Kernel patches / Docker restarts /
  reboots hit both at once. Sandbox's placeholder secrets and
  half-configured OAuth become part of prod's attack surface. Sandbox
  can't be used to validate infra changes (instance type, AMI, IAM
  role) because doing so is doing it to prod. The 0.4% CPU figure
  holds only while prod is idle.

- **Move sandbox to its own EC2** (as PR #3 currently proposes).
  Cleaner isolation, lets sandbox break freely, lets us test infra
  changes. Costs ~$30/month and doubles the ops surface for a small
  team.

The decision substantially determines the shape of PR #3 — see that
PR's discussion. Needs Tek's call before PR #3 can move forward.

## Security posture (observations from `discovery.md`)

The production security group (`launch-wizard-25`) has several things
worth revisiting:

- **SSH port 22 is open to `0.0.0.0/0`.** Predates any CI ambition.
  See "SSH access / SSM adoption" below for the intended replacement.
- **pgAdmin (port 5051) is publicly reachable.** Database admin UI on
  the open internet.
- **Oxigraph HTTP (port 7878) is publicly reachable.** Depending on
  SPARQL auth, either intentional read access or an unintentional
  write vector.
- **Every application port is `0.0.0.0/0`** — 3000, 8000, 8004, 8007,
  8010, 8080. The ALB in front of these services is effectively
  cosmetic today; direct-port access bypasses HTTPS, domains, and any
  ALB-enforced routing.

None of these are "wrong" per se — they may all be intentional given
the current deployment shape. Worth pinning down with Tek which are
intentional and which are hardening opportunities.

## Cost and sizing

Prod runs `c5.4xlarge` — roughly $0.60–0.70/hour on-demand, several
hundred dollars per month for compute alone. Utilization is ~0.4% CPU
per `bootstrap.md`, so this is not proportional to load.

Not something to change today for production. Relevant for sandbox:
if sandbox ends up on its own instance (see co-tenant decision above),
`t3.small` or `t3.medium` is a reasonable starting size — order of
magnitude cheaper — since sandbox does not need to match prod's
capacity.

## SSH access / SSM adoption

Production EC2 has no IAM instance profile attached today
(`discovery.md` §IAM). Attaching one is the natural first step for:

- **SSM Session Manager** — replaces SSH:22 with authenticated,
  logged sessions using the instance's IAM role, and lets us close
  port 22 to the internet entirely.
- **S3 role-based access** — eliminates static credentials for
  FSx/S3 interaction.

Not blocking today; a prerequisite before any of those adoptions.

## Secrets Manager

Placeholder — referenced from `discovery.md` and PR #3 comments.
Intent: rotated, role-based secret access instead of static values in
`.env` files. Depends on the IAM instance profile above. Full design
TBD.

## FSx for Lustre (persistent storage architecture)

Placeholder — referenced from PR #3's `tofu/modules/brainkb/storage.tf`
stub. Production's Oxigraph data lives on an FSx for Lustre filesystem
mounted at `/fsx/brainkb-kg-repo`. Sandbox uses a plain Docker named
volume today. Whether sandbox needs to mirror the FSx setup is
deferred. Full design TBD once FSx filesystem details are captured
(see `discovery.md` "Data gaps").

## S3 (backup / data-repository path)

Placeholder — referenced from PR #3's `tofu/modules/brainkb/storage.tf`
stub. The S3 bucket linked to FSx as its data-repository association
is also the current backup path per Tek. Bucket ID, versioning, and
sync direction TBD.

## Sandbox in a partial state

Security group `sg-02e6912482926898b` exists in AWS and is referenced
by three inbound rules on the production EC2's SG (ports 13000, 18004,
18007 — the sandbox UI + two sandbox services). What that SG is
attached to is not yet discovered — clarifies whether sandbox
currently has any dedicated network interfaces or is fully co-tenanted
on prod's compute. See `discovery.md` "Data gaps." Feeds directly into
the co-tenant decision above.

## Sandbox ALB / DNS plan (contingent on the co-tenant decision)

If sandbox gets dedicated compute:

- Sandbox ALB spans all three subnets for multi-AZ resilience.
- New Route 53 records under `Z06918342ADZVPCW09HXW` (ALIAS records
  pointing at the sandbox ALB), replacing the stale `sandbox.` A
  record noted in `discovery.md` / `sandbox/notes.md`.
- Host-based routing on a single ALB for three sandbox domains, per
  `sandbox/notes.md`'s current pattern.

If sandbox stays co-tenanted, most of this changes shape — the ALB
and DNS records still exist, but the target group points at prod's
existing EC2 rather than a new one.

## ALB architecture for production

Production currently uses **three separate ALBs**, one per domain
(`beta.`, `usermanagement.`, `mlservice.`), dig-verified via distinct
IP sets (see `bootstrap.md`). Sandbox uses a **single ALB with
host-based routing** for its three domains (see `sandbox/notes.md`).

Both patterns work. Whether production should eventually migrate to
sandbox's single-ALB pattern is a separate question — cheaper (one
ALB vs three) but requires a migration path. Not on the roadmap
today; noted here so the option isn't lost.

## Data-gap priority

The gap list in `discovery.md` in rough order of downstream impact:

1. **ALB inventory** — needed for prod-import work, not sandbox.
2. **FSx filesystem details** — needed before codifying persistent
   storage.
3. **Sandbox SG (`sg-02e6912482926898b`) attachment** — clarifies
   sandbox's current state, feeds the co-tenant decision.
4. **S3 bucket inventory** — the FSx-linked bucket, plus any others.
