# brainkb-infrastructure

Deployment configuration (sandbox + production) for BrainKB: OpenTofu for the AWS
resources, PyInfra for setting up the server, and the compose files and env templates
the apps run with.

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

## How the pieces fit

Two tools, two jobs:

- **OpenTofu** (`tofu/`) builds the AWS side: the server, its disk,
  security groups, the load balancer, HTTPS certificate, DNS names, and
  the FSx for Lustre drive with its S3 bucket. Each change is a plan you
  read and then apply.
- **PyInfra** (`pyinfra/`) sets up what runs on that server: swap,
  Docker, Node/PM2, the three repo checkouts, both env files, the backend
  stack, the UI, and the FSx mount. One command, safe to re-run; it reads
  the server it targets from `tofu output`.

Secrets (passwords, OAuth client secrets, session keys) are never in this
repo. For the sandbox they also aren't in files on anyone's laptop: they
live in **AWS SSM Parameter Store** under `/brainkb/sandbox/`, and PyInfra
fills them into the env templates at deploy time.
`pyinfra/push-secrets.py` stores or updates one. Production still keeps
its secrets in `.env` files on its server.

Where things stand:

| | Sandbox | Production |
|---|---|---|
| Address | test.brainkb.org (and `usermanagement.`, `mlservice.`, `queryservice.` under it) | brainkb.org |
| Server built by | OpenTofu (`tofu/environments/sandbox/`) | by hand; adopted into OpenTofu as-is (`tofu/environments/production/`, import only) |
| Set up by | PyInfra (`pyinfra/`) | by hand |
| Oxigraph data | Server's disk (`/home/ubuntu/oxigraph-db`); nightly backups to FSx at `/fsx/backups` | Server's disk (`/home/ubuntu/oxigraph-db`), backups to FSx (per production's recovery runbook) |
| Secrets | SSM Parameter Store, `/brainkb/sandbox/` | `.env` files on the server |

The older sandbox at sandbox.brainkb.org runs on the production server
beside production, set up by hand from `sandbox/`. Its data was copied to
test.brainkb.org with `pyinfra/copy-old-graph.sh`; it's kept running for
now.

### Standing up or updating the sandbox

From a laptop with AWS access (`aws sso login --profile sensein-sso`):

1. `tofu/environments/sandbox/`: `tofu plan -var-file=sandbox.tfvars`,
   then `tofu apply -var-file=sandbox.tfvars` (see its README).
2. From the repo root: `pyinfra pyinfra/inventory.py pyinfra/deploy.py`
   (see `pyinfra/README.md`; add `--data build_ui=false` to skip the
   ten-minute UI build).

Day to day, only step 2 is needed: it updates the app code and restarts
what changed. The server runs this repo at the same commit as your
checkout, so `git pull` first; the deploy stops if your changes aren't
committed and pushed, and asks before deploying a checkout that's behind
GitHub.

## Layout

```
brainkb-infrastructure/
├── README.md
├── decisions.md              # why things are set up the way they are
├── discovery.md              # inventory of the hand-built production AWS resources
├── bootstrap.md              # one-time, non-automatable host/AWS setup
├── bootstrap/state/          # OpenTofu: the S3 bucket + lock table that hold tofu's state
├── tofu/
│   ├── modules/brainkb/      # server, SGs, IAM, ALB, cert, DNS, FSx + S3
│   └── environments/
│       ├── sandbox/          # test.brainkb.org, built with the module
│       └── production/       # adopts the existing production resources
├── pyinfra/                  # server setup for the tofu sandbox
│   ├── inventory.py          # finds the server from `tofu output`
│   ├── deploy.py             # the setup steps
│   ├── ssh-via-ssm.sh        # SSH without an open port 22
│   ├── push-secrets.py       # store secrets in SSM Parameter Store
│   ├── copy-old-graph.sh     # one-time copy of the old sandbox's data
│   └── README.md
├── production/
│   ├── docker-compose.yml    # backend only — see "What this repo orchestrates" above
│   ├── backend.env.template
│   ├── ui.env.template       # becomes brainkb-ui's .env.local; PM2 deploy, not Docker
│   └── README.md
├── sandbox/
│   ├── docker-compose.yml    # same shape, sandbox-scoped names/network/ports
│   ├── backend.env.template
│   ├── ui.env.template
│   ├── new-server-setup.md   # the manual version of what PyInfra does
│   └── README.md
└── .github/workflows/
    ├── tofu.yml              # fmt + validate on every PR that touches tofu/
    ├── sandbox-deploy.yml    # manual dispatch, pick ui_branch + backend_branch
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

- **Sandbox (test.brainkb.org):** built by OpenTofu, set up by PyInfra,
  secrets in SSM, nightly graph backups to FSx, data copied from the old sandbox.
- **Production:** described in OpenTofu as it runs today, not yet applied
  (the first apply only records the existing resources, and changes
  nothing). Still set up and deployed by hand.
- **Not yet automated:** OAuth callback URLs at GitHub/ORCID/Globus, MCP,
  Ollama, production's server setup, and backups and graph history
  beyond the sandbox's nightly export (rules to be settled in #24).

See each environment's README, `pyinfra/README.md`, and `bootstrap.md` for
details, and `decisions.md` for the reasoning.
