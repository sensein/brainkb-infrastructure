# brainkb-infrastructure

Deployment configuration (sandbox + production) for BrainKB.

## Why this repo exists

BrainKB today is split across two application repos:

- [`sensein/brainkb-ui`](https://github.com/sensein/brainkb-ui) — Next.js frontend
- [`sensein/BrainKB`](https://github.com/sensein/BrainKB) — Python backend (API token
  manager, query service, ML service, user management service, Oxigraph SPARQL store)

Each app repo previously carried its own ad hoc compose files and shell deploy scripts, with
no single place that described how the two fit together as one deployed system — and that gap
was already causing real problems: `brainkb-ui`'s own sandbox compose never joined the backend
network, so sandbox never actually exercised the full stack; `BrainKB/chat_service` has its own
separate compose file nothing else references; env vars were duplicated inconsistently across
both repos. This repo centralizes that: the backend's docker-compose stack, env templates for
both apps, the manual-setup runbook (`bootstrap.md`), and CI workflows, for both **sandbox**
and **production**.

## What this repo actually orchestrates (and what it doesn't)

The backend runs in Docker — this repo's compose files own that. **The frontend does not run
in Docker** in either environment: an earlier attempt to containerize both UI and backend
together hit an issue where Next.js couldn't reach the backend over the shared Docker
network — really a `NEXT_PUBLIC_*`-vars-need-real-public-URLs problem, not an unfixable Docker
one (`brainkb-ui`'s own `bin/up.sh` Docker path does solve it correctly, by baking those vars
as build args). Production (and sandbox) instead deploy the UI directly on the host via PM2,
using `brainkb-ui`'s own `bin/up-node.sh` — confirmed directly with the person who deploys
this. This repo still owns the UI's env template (`ui.env.template`) so both halves of the
deploy are documented in one place, but it doesn't run or build the UI itself.

This was originally modeled loosely on
[dandi-infrastructure](https://github.com/dandi/dandi-infrastructure), but that comparison
turned out to be a poor fit worth naming: DANDI's infra repo provisions zero compute — its app
runs on Heroku (a PaaS), so their Terraform only manages DNS/S3/cert/Heroku-app-config. BrainKB
has no PaaS underneath it; this repo *is* the compute orchestration layer, which is a
fundamentally different job.

## Design note: two repos today, by deliberate choice

`brainkb-ui` and `BrainKB` are kept as separate repos for now, each deployed from its own
branch. This is a decision, not an accident — DANDI itself merged its backend and frontend
into one repo (`dandi-archive`) after finding two-repo coordination painful, and BrainKB may
end up doing the same. Nothing here should assume the split is permanent:

- The backend compose file references `BrainKB` via a `${BACKEND_REPO_PATH}` build-context
  variable (defaulting to a sibling checkout `../BrainKB`), not a hardcoded path.
- Both apps' env templates already live side by side here, so a future single-repo merge
  doesn't force a reorganization.
- The GitHub Actions workflows take `ui_branch` / `backend_branch` as independent inputs so
  they naturally collapse to "one branch" if the repos merge.

## Layout

```
brainkb-infrastructure/
├── bootstrap.md              # one-time, non-automatable host/AWS setup (FSx, ALB, DNS, ...)
├── production/
│   ├── docker-compose.yml    # backend only — see "What this repo orchestrates" above
│   ├── backend.env.template
│   ├── ui.env.template       # becomes brainkb-ui's .env.local; PM2 deploy, not Docker
│   └── README.md
├── sandbox/
│   ├── docker-compose.yml    # same shape, sandbox-scoped names/network/ports
│   ├── backend.env.template
│   ├── ui.env.template
│   └── README.md
└── .github/workflows/
    ├── sandbox-deploy.yml     # manual dispatch, pick ui_branch + backend_branch
    └── production-deploy.yml # deploys main of both apps; also manually dispatchable
```

## Expected checkout layout

The backend compose file assumes `BrainKB` is checked out as a sibling of this repo:

```
some-parent-dir/
├── brainkb-infrastructure/
├── brainkb-ui/       # cloned/pulled directly on the deploy host, run via PM2 in place
└── BrainKB/
```

Override `BACKEND_REPO_PATH` in the environment (or in each `.env`) if your layout differs —
see `production/README.md` and `sandbox/README.md` for details.

## Status

This repo currently codifies what already exists and is confirmed working in `brainkb-ui` and
`BrainKB` — it does not yet add new infrastructure (Terraform/OpenTofu, automated production
triggers beyond a basic workflow). See each environment's README, and `bootstrap.md`, for
what's still manual or unconfirmed.
