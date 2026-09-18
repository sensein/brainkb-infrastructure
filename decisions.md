# Open decisions: OpenTofu + PyInfra adoption

Open questions that must be answered before we start writing `.tf` or `pyinfra` code.
See `README.md`, `bootstrap.md`, and `notes.md` for what exists today; the September 2026
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

**Lean.** Co-tenant for v1, but write the OpenTofu module with a `dedicated_instance` bool
var so we can flip to split later without a rewrite. Sandbox and prod already have
separate Docker networks and a `+10000` port offset (per recent commit); that's the
isolation boundary today, and it works.

**Verify.**

- Current instance type and monthly cost. Splitting doubles it (approximately).
- Explicit answer: are we OK with a sandbox load test potentially degrading prod?

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

**Lean.** Use SSH for PyInfra in v1 — matches the current operator workflow,
no new AWS surface to configure. Two operational items to nail down as v1
lands:

- Which SSH key does PyInfra use? Operator's personal key vs a dedicated
  deploy key stored somewhere durable (1Password, SSM, a GitHub Actions
  secret if CI drives deploys).
- Which source IPs can reach port 22? Confirm the current SG rule — operator
  IPs, a bastion, or open — before it becomes a security review finding.

**Follow-up: SSM Session Manager as a hardening step.** Once the SSH key
story starts hurting (especially when GitHub Actions needs to deploy — see
§9), SSM Session Manager becomes the simpler answer: no public :22, IAM
controls access, CloudTrail logs every session. Not blocking; note and
revisit.

---

## Second-tier decisions

Can wait past v1 sandbox; must resolve before prod cutover.

### 6. Prod ALB migration: 3 → 1

Prod has 3 ALBs today (per `notes.md`, dig-verified). Sandbox is being built as 1 ALB with
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

---

## Not on the table for v1

Restating the summary's §10 for the record: Kubernetes, ECS migration, autoscaling,
service mesh, blue/green deployment, multi-instance HA, and complex GitOps machinery are
all deferred. If a decision here would only make sense with one of those, defer the
decision too.
