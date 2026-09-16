# Sandbox

Same two-part shape as `production/` (Docker backend + PM2 UI), kept intentionally close to
it so drift stays visible in diffs. Confirmed fine to run on the **same EC2 instance** as
production (it's essentially idle — 0.39% CPU) — just needs its own network, container
names, and ports so nothing collides.

Differences from production:

- Network: `brainkb-sandbox-network` (separate from `brainkb-network`).
- Container names suffixed `-sandbox`, and separate named volumes.
- Backend ports are pre-offset (18000/18010/18007/18004/15432/17878/15051) so both stacks
  can run side by side on one host without colliding.
- No CPU/memory `deploy.resources` reservation on `brainkb-unified` — sandbox doesn't need
  production's 8-CPU/16GB floor.
- **No FSx/S3 mount needed** — sandbox's Oxigraph data just uses a plain Docker named volume
  (leave `OXIGRAPH_DATA_PATH`/`OXIGRAPH_TMP_PATH` blank in `.env`). FSx is a production-only,
  exact-replica concern.
- Domain naming mirrors production's convention with `.sandbox` inserted, e.g. production's
  `usermanagement.brainkb.org` → sandbox's `usermanagement.sandbox.brainkb.org`. **Live and
  working** — one shared ALB + one ACM cert + Route53 records for `sandbox.brainkb.org`,
  `usermanagement.sandbox.brainkb.org`, `mlservice.sandbox.brainkb.org` (query_service and
  chat_service stay direct-host-port, matching production's own pattern there). Full manual
  setup steps, decisions, and gotchas are in `notes.md` — start there if setting this up
  again from scratch.

## Part 1: Backend (this repo)

### Prerequisites

Same as production (see `../production/README.md`), but create the sandbox network instead:

```
docker network create brainkb-sandbox-network
```

(See production's README for why this has to be created manually — the
network is declared `external: true` in `docker-compose.yml` so its name
stays fixed. Only needed once per host.)

If `docker` commands fail with "permission denied ... docker.sock" and there's
no `docker` group on the host (`usermod: group 'docker' does not exist`),
prefix every `docker`/`docker compose` command with `sudo` instead.

`.env` in this directory, copied from `backend.env.template`.

### Deploy

```
cd sandbox
docker compose up -d --build
```

Typically driven by `.github/workflows/sandbox-deploy.yml`, which checks out `BrainKB` at
whatever branch you pick and runs this compose file against it.

## Part 2: Frontend (brainkb-ui, PM2 — not in this repo's compose)

Same as production's Part 2, but:
- Copy `ui.env.template` (this directory's version, with sandbox's `PORT=13000` default) to
  `brainkb-ui/.env.local` instead.
- Invoke `bin/up-node.sh` with `PM2_APP_NAME=brainkb-ui-sandbox PORT=13000` — both are
  natively env-overridable, so this coexists safely with production's `brainkb-ui` PM2
  process on the same host with no code changes needed.

**⚠ `brainkb-ui/.env.local` is a tracked file in that repo (not gitignored — see
`bootstrap.md`).** Copying `ui.env.template` over it overwrites brainkb-ui's own committed
version, not an ignored/untouched file. This means:
- `git status` in that checkout will show `.env.local` as locally modified, not untracked.
- A future `git pull` there can conflict with brainkb-ui's own committed `.env.local`,
  rather than silently leaving your copy alone the way a gitignored file would.
Check `git status` before pulling that checkout again, and be ready to resolve a conflict
on that specific file.

## Testing new code (once the initial setup above is already done)

The AWS side (ALB, target groups, DNS, certificate, security groups) is durable and
persists regardless of what code is deployed — none of it needs to be touched again for
routine testing. Only revisit it if adding a new domain/service. Everything below assumes
the checkouts already exist (e.g. under `~/sandbox-workspace/` on the EC2 instance) and
just need updating.

**Backend (BrainKB):**
```
cd BrainKB && git checkout <branch> && git pull
cd ../brainkb-infrastructure/sandbox && docker compose up -d --build   # (sudo if needed)
```
Confirm it's actually healthy afterward, not just that the containers started:
```
docker exec brainkb-unified-sandbox supervisorctl status
```
All 4 services (`api_tokenmanager`, `query_service`, `ml_service`,
`usermanagement_service`) should show `RUNNING` and stay that way — a service that starts
and then crash-loops (`BACKOFF`/`FATAL`) won't show up as broken from `docker ps` alone.

**Frontend (brainkb-ui):**
```
cd brainkb-ui && git status   # check before pulling — see the .env.local warning above
git checkout <branch> && git pull
PM2_APP_NAME=brainkb-ui-sandbox PORT=13000 bash bin/up-node.sh
```
This rebuilds the Next.js app (`NEXT_PUBLIC_*` values get baked in fresh each time) and
reloads the PM2 process in place.

**Verifying it's actually live**, not just that the process/container started:
```
curl -sI --max-time 10 https://sandbox.brainkb.org/
curl -sI --max-time 10 https://usermanagement.sandbox.brainkb.org/
curl -sI --max-time 10 https://mlservice.sandbox.brainkb.org/
```
Any real HTTP response (even a `404`/`405`) confirms the full chain works — DNS → ALB
(TLS) → target group → the service itself. See `notes.md` ("How to check whether a
domain is actually working end-to-end") for how to interpret the results, and what a
genuine failure looks like instead.

## Still open: loading data into Oxigraph

Sandbox's Oxigraph starts **completely empty** (plain Docker volume, no FSx — see
above), and there's no working path yet to load anything into it:
- The app's own ingest UI (`/user/ingest-kg`) needs a logged-in admin session, and login
  doesn't work yet (no OAuth providers configured — see `notes.md`).
- Going straight to Oxigraph's own SPARQL Graph Store protocol (bypassing the app) is
  possible in principle — it's Basic-Auth protected with `OXIGRAPH_USER`/`PASSWORD`,
  already set — but untested, and its port (`17878`) isn't open externally (only
  reachable from inside the instance, e.g. `curl localhost:17878`). Not yet confirmed
  what request format Oxigraph actually expects here.

Needs a real session to work through — not done, not blocking anything else.
