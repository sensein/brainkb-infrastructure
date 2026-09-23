# Open decisions: OpenTofu + PyInfra adoption

Open questions that must be answered before we start writing `.tf` or `pyinfra` code.
See `README.md`, `bootstrap.md`, and `sandbox/notes.md` for what exists today; the September 2026
architecture summary (OpenTofu + PyInfra) for the target shape. This file is a decisions
log — nothing here is final until we mark it so.

Convention:

- **Lean** — a recommendation to react to, not yet a decision.
- **Verify** — information we need to gather before deciding.
- **Answered** — response received; captures who and when. May settle the
  question, or reframe it into a follow-up.
- **Decided** — added once we agree; keep the reasoning above it.

---

## 1. FSx flavor for Oxigraph persistence

**Answered (2026-09-16, Tek).** Prod uses **FSx for Lustre** with an S3
data-repository association. That's the current baseline; codify it in v1.

**Residual follow-up (not blocking v1).** Whether to migrate off Lustre later
for cost/complexity reasons — Lustre is HPC-shaped and Oxigraph's I/O profile
is not. Revisit once the tofu module for Lustre is in and we have real cost
data. If we ever migrate, EFS or FSx for OpenZFS are the plausible targets.

---

## 2. Backup semantics for the graph store

**Answered (2026-09-16, Tek).** The FSx-to-S3 mirror **is** the backup story
— prod already has one configured, and recovery is via S3. Details are in a
Slack thread; not yet captured in this repo. No separate `oxigraph dump` job
is planned.

**Follow-up: capture from Slack.** The backup configuration currently lives
only in Slack. Port the concrete details (bucket name, sync direction,
retention/versioning settings, restore procedure) into `bootstrap.md` so it
survives Slack retention and stops being tribal knowledge.

**Residual risk to name, not a blocker.** FSx↔S3 mirror is filesystem
replication, not an application-consistent backup. It covers:

- EC2 disk loss / instance failure / region-scoped recovery.

It does **not** cover:

- Application-level corruption (Oxigraph mid-write when something goes
  wrong on the host).
- Accidental logical deletes (a bad `SPARQL DELETE`, a wrong migration).
- Ransomware or operator error propagating to S3 before it's noticed.

Recording this so accepting it is a conscious choice. If those failure
modes turn out to matter later, a periodic `oxigraph dump` to a separate
versioned bucket is the cheap add-on.

---

## 3. One EC2 instance or two

**Question.** `bootstrap.md` says sandbox and prod currently share one EC2 (idle at 0.39%
CPU). The architecture summary implies separate compute per environment. Do we split?

**Options.**

- **Co-tenant** (matches today). Cheap, one host to manage. Blast-radius risk: a sandbox
  misbehavior (OOM, port collision, docker daemon wedge) can degrade prod.
- **Split** (proposal default). Two EC2 instances. Safer, ~2x compute cost, more surface
  for PyInfra to reconcile. Sandbox becomes a genuine pre-prod test bed.

**Answered (2026-09-23, Tek).** Split is the target — sandbox and prod
should run on different EC2 instances so production is never at risk
from a sandbox issue. Co-tenant is fine transitionally while cutover
lands.

**Revised Lean.** Proceed with a dedicated sandbox EC2 in tofu (PR #3's
current shape). Sandbox stays co-tenanted on prod's instance until the
tofu-managed EC2 is live and its ALB target groups take over sandbox
traffic, at which point tear down the sandbox PM2 process, Docker
network, and shared SG rules on prod. The `dedicated_instance` bool
var from the earlier Lean is no longer needed — dedicated is the goal.

**Verify (still open).**

- What is SG `sg-02e6912482926898b` attached to? Referenced by three
  inbound rules on prod's SG (ports 13000, 18004, 18007 — sandbox UI +
  two sandbox services), but its own attachment isn't yet known. Run
  `aws ec2 describe-network-interfaces --filters Name=group-id,Values=sg-02e6912482926898b --region us-east-2`.
  Result tells us whether the tofu-managed sandbox EC2 should adopt this
  SG or create its own — and, either way, whether the shared SG rules
  on prod's SG can be dropped in the same cutover.

---

## 4. Ollama and GPU

**Answered (2026-09-16, Tek).** Prod runs Ollama on **CPU** — no GPU
instance. There's an open consideration to move to **AWS Bedrock** (or
another cheap managed provider) since BrainKB isn't deploying large models.

**Lean.** v1 codifies the current state — CPU-only Ollama, non-GPU EC2
instance family. Treat the managed-API migration as a separate follow-up
change once the provider decision is made; don't scope it into v1.

**Reframed question for later.** Self-hosted CPU Ollama vs Bedrock vs a
cheaper managed provider — cost, latency, model availability, and
data-egress considerations. Worth its own short comparison doc when the
team is ready to pick.

---

## 5. Host access path: SSH vs SSM Session Manager

**Answered (2026-09-16, Tek).** SSH access to the EC2 instance is available
today.

**Refined (2026-09-18, implementation spec §20).** SSH is fine for **human
operators from a laptop**. It is **not** fine to open `:22` to
`0.0.0.0/0` (or "the internet") so that GitHub Actions can reach the box.
Treat CI reachability into private infrastructure as an explicit
architecture decision, not a shortcut to widen an SG rule.

**Lean (v1, sandbox).** Use SSH from operator laptops for PyInfra during
sandbox bring-up. Two operational items to nail down as v1 lands:

- Which SSH key does PyInfra use? Operator's personal key vs a dedicated
  deploy key stored somewhere durable (1Password, SSM, a GitHub Actions
  secret if CI drives deploys).
- Which source IPs can reach port 22 today? Confirm the current SG rule —
  operator IPs, a bastion, or open — before it becomes a security review
  finding.

**Phased plan for CI connectivity (implementation spec §20).** When
PyInfra needs to run from GitHub Actions, pick one of these — do not just
widen the :22 rule:

1. **Self-hosted runner inside the VPC.** Simplest network reasoning; the
   runner has direct access. Costs: running and updating a runner host.
2. **SSM-based execution.** No public :22, no keys to distribute. IAM
   controls who can run commands; CloudTrail logs everything. Matches the
   original §5 lean.
3. **Controlled bastion / private connectivity.** Traditional; more
   moving parts than SSM but familiar patterns.

None of these blocks v1 sandbox from operator laptops. Pick one when CI
actually becomes the driver.

---

## Second-tier decisions

Can wait past v1 sandbox; must resolve before prod cutover.

### 6. Prod ALB migration: 3 → 1

Prod has 3 ALBs today (per `sandbox/notes.md`, dig-verified). Sandbox is being built as 1 ALB with
host-based routing. Migrating prod is a live DNS cutover, not a `tofu import`. It needs
its own runbook: TTL reduction ahead of time, per-domain flip, rollback plan, target-group
draining.

**Lean.** Land sandbox on the 1-ALB pattern, run it for a few weeks, then plan the prod
migration as its own change with a scheduled window.

### 7. `query_service` topology

Prod exposes `query_service` on host:8010 directly, no ALB (per `bootstrap.md`). Options:
keep the direct-port pattern (breaks the "everything behind the ALB" model), or move it
behind `queryservice.brainkb.org` (breaking change for any hardcoded clients, including
`NEXT_PUBLIC_QUERY_SERVICE_URL` or equivalent in `.env.local`).

**Lean.** Move it behind the ALB as part of the 3→1 migration. Same ALB, new host-based
rule, matching ACM SAN. Env var updates ship in the same PR.

### 8. Secrets: SSM SecureString vs Secrets Manager

The summary says "Secrets Manager / SSM" as if interchangeable. They aren't: SSM
SecureString is free; Secrets Manager is $0.40/secret/month + built-in rotation hooks.

**Lean.** SSM SecureString as the default. Upgrade individual secrets to Secrets Manager
only when we want automatic rotation (probably: RDS credentials if/when we adopt RDS).

**Also.** The two secrets `bootstrap.md` §Credentials flags for rotation
(`MONGO_DB_URL` embedded password; `CHAT_SERVICE_JWT_SECRET_KEY`) should rotate as part of
moving them into SSM, not after.

### 9. CI/CD: laptop-driven or GitHub Actions

Repo already has `sandbox-deploy.yml` and `production-deploy.yml`. The summary is silent
on whether `./scripts/deploy sandbox` runs locally, in Actions, or both.

**Lean.** Both, from the same script. Actions authenticates to AWS via **OIDC** (no static
IAM user keys). Prod requires manual approval via a GitHub Environment protection rule.

### 10. Idempotence of `start_service.sh` / `up-node.sh`

The summary flags making these idempotent as work to do — and that's cross-repo work.
Cheaper alternative: leave the scripts as-is, put the idempotence in PyInfra facts (check
"expected container running with expected image digest? PM2 process `X` online?" and only
call the script when reconciliation is needed).

**Lean.** PyInfra-facts approach. Don't force cross-repo shell rewrites unless the fact
approach can't express what we need.

### 11. Production security-group hardening

**Question.** Prod's SG (`launch-wizard-25`) has several ports open to
`0.0.0.0/0` — observed while capturing `discovery.md`. Which of these are
intentional design and which are drift-through-history? What tightens, and
when?

The observed exposure (from `discovery.md` §Security groups):

- **SSH:22** open to the internet. Covered separately by §5 (SSH/SSM);
  noted here so the SG-hardening discussion doesn't miss it.
- **pgAdmin (5051)** publicly reachable. **Answered (2026-09-23, Tek):
  intentional — public web access is needed to reach it at all. Not
  tightening.**
- **Oxigraph HTTP (7878)** publicly reachable. **Answered (2026-09-23,
  Tek): intentional — same rationale as pgAdmin, kept public.**
- **Every application port** — 3000, 8000, 8004, 8007, 8010, 8080 —
  open to `0.0.0.0/0`. **Direct-port access bypasses the ALB entirely**,
  which means the ALB in front of these services is effectively cosmetic
  today. The §6 ALB migration (3 → 1) buys much less than it appears to
  as long as this is true. Whether to tighten these to ALB-only is still
  open.

**Options (for the still-open app-port question).**

- **Leave as-is.** Matches current behavior; nothing breaks. Continues to
  make ALB routing/TLS/host-based rules bypassable.
- **Tighten app ports to ALB-only.** Change each app-port rule's source
  from `0.0.0.0/0` to the ALB's security group. Forces traffic through
  the ALB, making the §6 migration meaningful. Requires knowing every
  external caller relies on the domain, not the direct IP:port. Risk:
  hardcoded `IP:port` clients (e.g. `NEXT_PUBLIC_QUERY_SERVICE_URL`
  today) break silently.

**Revised Lean.** With pgAdmin and Oxigraph confirmed intentional, the
remaining hardening work on prod's SG is: (1) close SSH:22 to the
internet as part of §5's SSM adoption, and (2) tighten the six app
ports to ALB-only as part of §6 — that's the missing piece that makes
the 3-ALB → 1-ALB migration actually enforce routing/TLS instead of
being cosmetic. Not blocking v1 sandbox (sandbox brings its own SG
that we control from day one).

**Verify (still open).**

- Which callers (external services, scripts, dashboards) still use
  direct `IP:port` for prod's app ports? A change under §6 breaks them.
  Worth enumerating before the ALB migration ships.

---

## Architecture directions from the implementation spec

Items the September implementation brief calls out as target-state or
workflow discipline. Not decisions to make now, but not things to forget
either.

### Private EC2 behind ALB (spec §7)

The target networking model is:

    Internet → IGW → public subnets → ALB → private subnets → EC2 → FSx

Current prod EC2 is public (per `bootstrap.md`). Moving to a private
subnet is a v2 concern, not a v1 blocker: it interacts with §5 (host
access path) and §7 in the second-tier list (`query_service` currently on
direct host:port). Record the direction so v1 doesn't design around a
public-EC2 assumption we'd have to walk back.

### GitHub workflow concurrency groups (spec §21)

Every deployment workflow must set a concurrency group scoped to its
environment (e.g. `brainkb-sandbox`, `brainkb-production`) with
`cancel-in-progress: false`. Prevents two `tofu apply` (or PyInfra) runs
from racing on the same state file / host. Trivial to add when we write
the workflows; easy to forget until two deploys collide.

### Separate infra deploys from app deploys (spec §22)

Long-term: a change to `brainkb-infrastructure` runs OpenTofu + PyInfra;
a change to `brainkb-backend` or `brainkb-ui` runs only PyInfra's
app-deployment tasks (no `tofu apply` when infra didn't change). v1 can
use a single workflow that always runs both — the spec explicitly permits
"one simpler deployment workflow first, then optimize triggers later."
Splitting is an ergonomic optimization, not a correctness requirement.

---

## Not on the table for v1

Restating the summary's §10 for the record: Kubernetes, ECS migration, autoscaling,
service mesh, blue/green deployment, multi-instance HA, and complex GitOps machinery are
all deferred. If a decision here would only make sense with one of those, defer the
decision too.
