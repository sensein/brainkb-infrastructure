# Bootstrap

One-time, manual, non-automatable setup that has to exist before either `production/` or
`sandbox/` can be deployed. None of this lives in git anywhere else — it's AWS console state
and host-level setup that only exists in a coworker's head (or the AWS console itself) unless
written down here. Modeled on how DANDI documents the same kind of gap in its own
`bootstrap.md`, including leaving items as open TODOs rather than guessing.

## EC2 host

- Both `production/` and `sandbox/` are confirmed to run (or will run) on the same EC2
  instance — confirmed fine, instance is essentially idle (0.39% CPU at last check).
- TODO: instance type, region, AMI — check EC2 → Instances.
- Deploy access today is manual: clone/pull the two app repos onto the instance directly, no
  CI runner or SSH-orchestrated automation exists yet.

## Domain, load balancer, TLS

- Confirmed pattern: **one ALB per domain that needs a domain name mapped to it** (not one
  shared ALB) — "if you don't need a domain, you don't need a load balancer." Multiple ALBs
  already exist for this reason.
- ACM issues the certificate for a given domain; Route53 holds the DNS records. Both are
  manual console steps today (Route53 → Hosted zones → `brainkb.org` → create a record;
  Certificate Manager → request a certificate for that domain if it needs SSL; EC2 → Load
  Balancers → create an Application Load Balancer → map it to the domain/cert).
- **Confirmed live today (dig-verified against Tek's real `env_ui_tek.txt`/`env_backend_tek.txt`),
  and this is the real current architecture — not every service has its own domain yet:**
  - `beta.brainkb.org` — the UI itself (`NEXTAUTH_URL` in Tek's real `.env.local`). 3 IPs,
    ALB-backed.
  - `usermanagement.brainkb.org` — usermanagement_service. 3 IPs, ALB-backed.
  - `mlservice.brainkb.org` — ml_service, also confirmed migrated to its own domain (this was
    guessed wrong earlier as still-direct-port; Tek's real file shows it's already domained).
    3 IPs, ALB-backed.
  - `mcp.brainkb.org` — a fourth confirmed-live domain (3 IPs, ALB-backed); relationship to
    the above isn't fully pinned down — worth asking what specifically it fronts.
  - **query_service is confirmed NOT on its own domain** — reached directly via the EC2
    instance's public IP on port 8010 (visible in Tek's real `.env.local`; the exact IP is
    operational detail, not reproduced here — see `env_ui_tek.txt` if you need it).
  - **chat_service is confirmed unused** — Tek's real file points it at bare `localhost:8011`,
    consistent with "not currently deployed."
  - `api.`, `queryservice.`, `ingest.` subdomains referenced in older app-repo code/docs do
    **not** currently resolve — don't trust code comments for this, they're stale.
  - **Bug spotted (not ours to fix, flagging for awareness)**: Tek's real
    `NEXT_PUBLIC_API_ADMIN_EXTRACT_STRUCTURED_RESOURCE_ENDPOINT` is missing a `/` between the
    domain and path (`mlservice.brainkb.orgapi/ws/...`) — likely a live typo bug on that one
    endpoint. Worth mentioning to him, not something to silently correct on his behalf.
- Sandbox convention: mirror production's domain with `.sandbox` inserted, e.g. production's
  `usermanagement.brainkb.org` → sandbox's `usermanagement.sandbox.brainkb.org`, same for
  `mlservice.`. Each needs its own ALB + ACM cert + Route53 record, not shared with
  production's. Sandbox's query/chat can stay direct-host-port the same way production's
  query_service currently is (18010/18011).
- TODO: confirm which ALB(s) back each of the four live domains — via EC2 → Target Groups
  (search for the production instance ID among registered targets) → the ALB(s) that
  reference it → their listener rules.

## Credentials handled in this session — consider rotating

While cross-checking Tek's real env files against our templates (2026-09-15), two secrets
were exposed in the process before the redaction tooling was fixed to catch them:
- A commented-out `CHAT_SERVICE_JWT_SECRET_KEY` value (chat_service is unused, so low
  urgency, but it's a real key and was exposed).
- The embedded username/password inside `MONGO_DB_URL` (this one is actively used by
  ml_service — worth rotating with more urgency).

Neither value is reproduced anywhere in this repo. Flagging here so the decision to rotate
(or not) is made deliberately rather than the exposure going unnoticed.

## Oxigraph storage (FSx + S3) — production only

- Production's Oxigraph data lives on an AWS FSx filesystem (mounted at the OS level, e.g.
  `/fsx/brainkb-kg-repo`), which is itself backed by an S3 bucket as its data repository.
- Order of operations: create the FSx filesystem (linked to an S3 bucket) in the FSx console
  → mount it on the EC2 host via plain Linux `mount`, **before** `docker compose up` →
  point `OXIGRAPH_DATA_PATH` at the mount point.
- **Not needed for sandbox** — sandbox's Oxigraph just uses a plain Docker named volume.
  Confirmed: "it might not be necessary, you just deploy and use... if you want to replicate
  exact thing as production, you might as well want to create FSx mapping."
- TODO: confirm the current FSx filesystem ID and S3 bucket it's linked to.

## GPU / Ollama

- `BrainKB/start_services.sh` starts Ollama outside of docker-compose entirely, via a raw
  `docker run`, auto-detecting GPU support via `nvidia-smi` / `nvidia-container-toolkit`.
- TODO: confirm whether production's instance type is actually GPU-equipped
  (`g4dn.*`/`g5.*`/`p3.*` etc.) or running Ollama in CPU mode.

## chat_service

- Confirmed **not currently deployed or used** in production. `BrainKB/chat_service` has its
  own separate `docker-compose-prod.yml` that nothing else references — out of scope until
  that changes.

## Frontend deploy: bin/up-node.sh (PM2) — confirmed what's actually used

- `brainkb-ui` ships **two** fully-documented, non-deprecated deploy paths: `bin/up-node.sh`
  (PM2, on the host) and `bin/up.sh` (Docker, full stack, bakes `NEXT_PUBLIC_*` as build args —
  this is also the actual fix for the earlier "Next.js can't reach backend" problem: it was
  never a Docker-networking bug, `NEXT_PUBLIC_*` vars execute in the browser so they always
  needed real public URLs baked in, not container hostnames).
- **Confirmed directly, twice, by the person who deploys this: production uses
  `bin/up-node.sh`, not `bin/up.sh`.** Treat the Docker path as a real, working, documented
  alternative that exists in the repo — not what's live today.
- Earlier note in this file about a hardcoded PM2 process name was based on the WRONG script
  (`deploy_without_docker.sh`, which is dead — see below) and has been retracted.
  `bin/up-node.sh` already supports `PM2_APP_NAME` (default `brainkb-ui`) and `PORT` as
  environment overrides — no code fix needed. Sandbox just runs:
  `PM2_APP_NAME=brainkb-ui-sandbox PORT=3080 ./bin/up-node.sh`.

## Known dead code in brainkb-ui (confirmed unreferenced, not just suspected)

- `deploy_without_docker.sh`, `clean_and_deploy.sh`, `sandbox_clean_and_deploy.sh`, and
  `ohbm-hackathon/` are not mentioned anywhere in current `README.md`,
  `DEVELOPER_DOCUMENTATION.md`, or `API_CONFIGURATION.md` — leftover cruft, not something to
  build tooling around. Consistent with cleanup already planned by the app-repo maintainers.
- `docker-compose-sandbox.yml` in `brainkb-ui` is a **false friend**: its own header says it's
  for local UI dev-loop iteration against a running backend (bind-mounted source, no
  rebuild needed) — explicitly not for real deployments. Different meaning of "sandbox" than
  this repo's `sandbox/` (a staging deployment environment). Don't reuse it for that purpose.
- A duplicate/unclear **backend** deploy path was also noticed during a live walkthrough
  (something beyond just `start_services.sh` vs `docker-compose.unified.yml` directly) —
  confirm `start_services.sh` is the one actually used before assuming otherwise.
- An old reference-only directory in `BrainKB` is slated for removal by the app-repo
  maintainers.

## Backups

- TODO: no backup/snapshot process for Postgres or Oxigraph data has been found or confirmed
  to exist. Worth explicitly deciding this is (or isn't) acceptable, rather than leaving it
  unexamined.
