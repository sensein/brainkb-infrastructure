# Open decisions: OpenTofu + PyInfra adoption

Open questions that must be answered before we start writing `.tf` or `pyinfra` code.
See `README.md`, `bootstrap.md`, and `notes.md` for what exists today; the September 2026
architecture summary (OpenTofu + PyInfra) for the target shape. This file is a decisions
log — nothing here is final until we mark it so.

Convention:

- **Lean** — a recommendation to react to, not yet a decision.
- **Verify** — information we need to gather before deciding.
- **Decided** — added once we agree; keep the reasoning above it.

---

## 1. FSx flavor for Oxigraph persistence

**Question.** Prod uses FSx with an S3 data-repository association (`bootstrap.md`).
Which FSx flavor is it, and is that the right choice for Oxigraph going forward?

**Options.**

- FSx for **Lustre** — HPC-oriented, expensive, POSIX-quirky, aggressive semantics on the
  S3 data-repository association (lazy load, export policies). Overkill for a SPARQL store.
- FSx for **OpenZFS** — POSIX-native, native snapshots, no S3 association (S3 sync becomes
  an application concern, not a filesystem one). Simpler mental model.
- **EFS** — POSIX-native, elastic, cheap infrequent-access tier. No data-repository
  semantics to trip on; S3 export is whatever we build.

**Lean.** Move off Lustre if that's what prod is currently on. EFS + an explicit
`oxigraph dump → S3` schedule (see §2) is likely the right shape given Oxigraph's I/O
profile — no HPC pattern, single-writer, occasional large reads.

**Verify.**

- Which FSx flavor is prod actually on? (`FSx → Filesystems → summary`.)
- Current monthly cost line for FSx. Baseline to compare against.
- Is the S3 data-repository association doing anything the app actually relies on today,
  or is it "on because it came with the wizard"?

---

## 2. Backup semantics for the graph store

**Question.** FSx↔S3 sync is filesystem replication, not an application-consistent backup.
Oxigraph writing mid-sync could leave the S3 side in an unrestorable state. What is the
real backup story?

**Options.**

- Periodic `oxigraph dump` (or a SPARQL `CONSTRUCT WHERE {?s ?p ?o}` export) to a
  versioned S3 bucket in a different region. Restore = load the dump into a fresh
  Oxigraph. Simple, correct, works regardless of FSx choice.
- FSx-level snapshots (OpenZFS supports this natively; Lustre does not).
- Do nothing (accept data-loss risk). Not viable for production.

**Lean.** Daily `oxigraph dump` → versioned S3 bucket, 30 days retention, cross-region.
Add as a systemd timer via PyInfra. Independent of whichever FSx flavor §1 lands on.

**Verify.**

- Current graph size on disk. Determines dump time and whether daily is feasible.
- What RPO/RTO are we actually willing to accept? A working assumption of RPO ≤ 24h,
  RTO ≤ 1h feels right for BrainKB's usage but should be stated, not assumed.

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

**Question.** `BrainKB/start_services.sh` runs Ollama outside compose via `docker run`
with GPU auto-detect. Is prod GPU-equipped? Is Ollama actively used in prod today?

**Options.**

- **GPU in prod** (e.g. `g4dn.xlarge`, `g5.xlarge`). NVIDIA driver + container toolkit go
  in the base AMI or in PyInfra. Ollama runs with `--gpus all`. Cost step-up is real.
- **CPU only.** Cheaper instance; Ollama runs CPU-only (much slower for real models).
- **No Ollama in prod at all.** Simplest. Drop from the deployment plan, mirror
  `chat_service`'s "confirmed not deployed" status.

**Lean.** Confirm current state first — this is a factual question, not a design one. If
Ollama is running in prod today, keep it and codify. If not, defer with a clear note.

**Verify.**

- Current EC2 instance family (per `bootstrap.md` TODO — check `EC2 → Instances`).
- Does prod's `.env` set Ollama-related URLs to a real endpoint, or `localhost` /
  blank / a stale value?
- Ask Tek: is Ollama actively used, or dormant like `chat_service`?

---

## 5. Host access path: SSH vs SSM Session Manager

**Question.** PyInfra needs to reach the EC2 host. Which access path do we standardize on?

**Options.**

- **Plain SSH on port 22.** SG must allow inbound 22 from somewhere (a bastion, operator
  IPs, or worse — the world). SSH key management becomes a real operational concern,
  especially from CI.
- **SSM Session Manager.** No public 22, no SSH keys. IAM controls who can connect. Every
  session is logged in CloudTrail. PyInfra can use it via
  `ssh -o ProxyCommand='aws ssm start-session ...'` or a dedicated SSM connector.

**Lean.** SSM Session Manager. Zero-inbound-22 SG, no keys to manage, free audit logs,
works identically from a laptop and from GitHub Actions.

**Verify.**

- Is the current EC2 already SSM-managed (instance role has
  `AmazonSSMManagedInstanceCore`)? If yes, this is a one-line SG change.
- Any operator preference against SSM we should know about?

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
