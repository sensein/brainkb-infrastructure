# Production

The real deploy is two independent parts on the same EC2 instance: the backend runs in
Docker (this compose file); the UI runs directly on the host via PM2 (`bin/up-node.sh`), not
Docker — confirmed directly with the person who deploys this. `brainkb-ui` also ships a
working Docker deploy path (`bin/up.sh` + `docker-compose.proxy.yml`) that bakes
`NEXT_PUBLIC_*` vars as build args, but that's not what's live today; see `bootstrap.md` at
the repo root.

## Part 1: Backend (this repo)

### Prerequisites

1. A checkout of `BrainKB` as a sibling of `brainkb-infrastructure` (or set
   `BACKEND_REPO_PATH` to point elsewhere):

   ```
   some-parent-dir/
   ├── brainkb-infrastructure/
   └── BrainKB/           # checked out at the branch/tag to deploy
   ```

2. The shared Docker network, created once per host:

   ```
   docker network create brainkb-network
   ```

3. The AWS FSx filesystem for Oxigraph data already mounted on the host (e.g. at
   `/fsx/brainkb-kg-repo`) via plain Linux `mount`, **before** `docker compose up`. This is
   not something Docker or this repo sets up — confirm the current filesystem ID / mount
   details before filling in `OXIGRAPH_DATA_PATH` / `OXIGRAPH_TMP_PATH`.

4. `.env` in this directory, copied from `backend.env.template` with real values filled in.

### Deploy

```
cd production
docker compose up -d --build
```

### Services

| Service           | Port (default) | Notes                                   |
|-------------------|-----------------|------------------------------------------|
| brainkb-unified   | 8000/8010/8007/8004 | API token manager / query / ml / usermanagement (supervisord, one container) |
| postgres          | 5432            | App DB for JWT / usermanagement / ml     |
| oxigraph-nginx    | 7878            | SPARQL store, basic-auth fronted         |
| pgadmin           | 5051            | Postgres admin UI                        |

`oxigraph` itself is not port-mapped — it's only reachable through `oxigraph-nginx`.
Ollama is not part of this compose file at all — it's started separately (see below).

## Part 2: Frontend (brainkb-ui, PM2 — not in this repo's compose)

1. Clone/pull `brainkb-ui` on the same host, at the branch to deploy.
2. Copy `ui.env.template` from this repo to `brainkb-ui/.env.local`, fill in real values.
   Note: the `NEXT_PUBLIC_*` vars are inlined into the browser bundle, so they must be real
   reachable URLs (a public HTTPS domain where one exists, otherwise the EC2 host's own
   address on the relevant port), not `localhost` — even though UI and backend run on the
   same instance.
3. Run `brainkb-ui`'s own `bin/up-node.sh` (PM2-based; `PM2_APP_NAME` and `PORT` are both
   env-overridable, default `brainkb-ui` / `3000`). `brainkb-ui/deploy_without_docker.sh` is
   dead code — don't use it, see `bootstrap.md`.

## Part 3: Ollama (optional, not in this compose file)

`BrainKB/start_services.sh` starts Ollama separately via a raw `docker run`, auto-detecting
GPU via `nvidia-smi`/`nvidia-container-toolkit`. Confirm whether this host actually runs with
a GPU before assuming either path — check the EC2 instance type (`g4dn.*`/`g5.*`/`p3.*` =
GPU-equipped; most other types are not).

## What's not automated yet / open gaps

- **TLS/domain routing**: confirmed live today: `beta.brainkb.org` (the UI),
  `usermanagement.brainkb.org`, `mlservice.brainkb.org`, and `mcp.brainkb.org`, each behind
  its own ALB + ACM cert. query_service is reached directly on the EC2 host's public IP, port
  8010 — not yet behind its own domain. See `bootstrap.md` at the repo root for the full
  picture and remaining TODOs.
- **chat_service**: not currently deployed/used in production — ignore it.
- **Backups**: no backup/snapshot process for Postgres or Oxigraph data has been found or
  confirmed to exist.
- The pgAdmin `servers.json` regeneration that `BrainKB/docker-compose-hook.sh` used to do
  before `docker compose up` isn't wired in here yet — run that script manually against your
  `.env` first if you rely on pgAdmin's pre-populated server list.
