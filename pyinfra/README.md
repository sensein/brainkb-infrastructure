# PyInfra: set up the sandbox server

`deploy.py` does steps 2–6 of `../sandbox/new-server-setup.md` on the
OpenTofu-managed sandbox instance in one command: swap, Docker,
Node/PM2, the three repos, both env files, the backend stack and the UI.
OpenTofu builds the server (`../tofu/environments/sandbox/`); PyInfra
sets up what runs on it.

It's safe to re-run. Each step skips what's already in place, so the same
command deploys new code, and also rebuilds a fresh instance from nothing.

| File | What it is |
|---|---|
| `inventory.py` | Finds the instance from `tofu output` |
| `deploy.py` | The setup steps |
| `ssh-via-ssm.sh` | Connects without port 22 (see "How it connects") |
| `fetch-secrets.sh` | One-time copy of the env files already on the server |
| `secrets/` | Your local secrets. Gitignored; never commit it. |

## One-time setup on your laptop

1. Python and PyInfra:

       python3 -m venv .venv && source .venv/bin/activate
       pip install -r pyinfra/requirements.txt

2. AWS access: the AWS CLI, the Session Manager plugin
   (`brew install --cask session-manager-plugin`), and an SSO login:

       aws sso login --profile sensein-sso
       export AWS_PROFILE=sensein-sso

3. OpenTofu initialised for the sandbox, so `tofu output` works:

       (cd tofu/environments/sandbox && tofu init -backend-config=backend.hcl)

4. An SSH key pair. Any key works; it's only used for the session (see
   below). If you don't have `~/.ssh/id_ed25519`:

       ssh-keygen -t ed25519

   To use a different key: `export BRAINKB_SSH_KEY=~/.ssh/other_key`.

## Secrets

The deploy reads two files that you keep locally:

- `pyinfra/secrets/backend.env`: values for the backend `.env`
  (passwords, JWT secrets, API keys).
- `pyinfra/secrets/ui.env`: values for the UI `.env.local`. Only
  `NEXTAUTH_SECRET` is required.

Each is `KEY=value` lines. They're merged into `sandbox/backend.env.template`
and `sandbox/ui.env.template`. Ports, the `test.*` URLs, `CORS_ALLOWED_ORIGINS`
and the Oxigraph paths are always set by `deploy.py`, so it doesn't matter
if the secrets files still carry the co-tenant sandbox's values.

The sandbox was first set up by hand, so the easiest start is to copy its
current env files down:

    pyinfra/fetch-secrets.sh

For a brand-new setup, write the two files by hand instead. Generate the
session key with `openssl rand -base64 32`.

A later change moves these into AWS SSM Parameter Store
(`decisions.md` §8), so nobody needs local files.

## Run it

From anywhere in the repo:

    pyinfra pyinfra/inventory.py pyinfra/deploy.py

PyInfra first lists what would change on the server and asks before
doing it. Add `-y` to skip the question.

Options (`--data key=value`, repeatable):

| Option | Default | Use |
|---|---|---|
| `brainkb_branch` | `main` | Deploy a BrainKB branch |
| `ui_branch` | `main` | Deploy a brainkb-ui branch |
| `infra_branch` | `main` | Branch of this repo checked out on the server (compose file) |
| `build_ui` | `true` | `false` skips the UI rebuild, which takes ~10 minutes |

For example:

    pyinfra pyinfra/inventory.py pyinfra/deploy.py --data brainkb_branch=my-feature --data build_ui=false

The run ends by checking that all four backend services are `RUNNING` and
that the UI answers 200 on port 3000. It fails if they don't.

## How it connects

The sandbox instance has no inbound SSH port (by design; see the tofu
sandbox README). `ssh-via-ssm.sh` is used as the SSH `ProxyCommand`. It:

1. pushes your public key to the instance with **EC2 Instance Connect**
   (valid for 60 seconds, so no permanent key is installed on the
   server), then
2. opens an **SSM Session Manager** tunnel to the instance's sshd and
   carries the SSH connection over it.

`inventory.py` writes `pyinfra/.ssh_config` (gitignored) with this set up.
You can use it for a normal shell too:

    ssh -F pyinfra/.ssh_config "$(cd tofu/environments/sandbox && tofu output -raw instance_id)"

This is option 2 ("SSM-based execution") of `decisions.md` §5.

## Not covered

- Creating the server itself: that's `tofu apply`.
- OAuth callback URLs at GitHub/ORCID/Globus.
- Loading data into Oxigraph, MCP, Ollama, and production.
