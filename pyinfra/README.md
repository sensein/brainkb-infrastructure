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
| `push-secrets.py` | Stores secrets in SSM Parameter Store (see "Secrets") |
| `fetch-secrets.sh` | One-time copy of the env files already on the server |
| `secrets/` | Optional local secrets, only for the one-time move or `secrets_source=local`. Gitignored; never commit it. |

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

Secrets live in **AWS SSM Parameter Store**, one encrypted `SecureString`
parameter per key, so nobody needs a secrets file:

- `/brainkb/sandbox/backend/<KEY>` for the backend `.env` (passwords, JWT
  secrets, API keys, OAuth client IDs and secrets)
- `/brainkb/sandbox/ui/<KEY>` for the UI `.env.local` (only
  `NEXTAUTH_SECRET` is required)

`deploy.py` reads them with your AWS credentials when you run it, merges
them into `sandbox/backend.env.template` and `sandbox/ui.env.template`, and
writes the result to the server. Ports, the `test.*` URLs,
`CORS_ALLOWED_ORIGINS` and the Oxigraph paths are always set by
`deploy.py`, so stored values for those don't matter.

Day to day, use `push-secrets.py`:

    pyinfra/push-secrets.py backend --list                     # key names (never values)
    pyinfra/push-secrets.py backend --set GLOBUS_CLIENT_SECRET # prompts for the value

Then re-run the deploy (`--data build_ui=false` if only backend values
changed). Avoid `aws ssm put-parameter --value ...` for secrets: it leaves
the value in your shell history.

**One-time move from local files.** For a server that was set up by hand,
or if you already have `pyinfra/secrets/*.env`:

    pyinfra/fetch-secrets.sh                                   # copies the server's env files down
    pyinfra/push-secrets.py backend pyinfra/secrets/backend.env
    pyinfra/push-secrets.py ui pyinfra/secrets/ui.env
    rm -r pyinfra/secrets                                      # no longer needed

Empty values are skipped (SSM doesn't store empty strings; they render as
the template's blank default). For a brand-new setup, store each key with
`--set`. Generate the session key with `openssl rand -base64 32`.

To deploy from local files instead (offline, or before the parameters
exist), add `--data secrets_source=local`; it reads
`pyinfra/secrets/backend.env` and `ui.env`.

Who can read them: anyone whose AWS role allows `ssm:GetParameter*` on
`/brainkb/sandbox/*` and `kms:Decrypt` on the default `aws/ssm` key. The
SSO AdministratorAccess role can. Standard parameters with the AWS-managed
key are free.

## Run it

From anywhere in the repo:

    pyinfra pyinfra/inventory.py pyinfra/deploy.py

PyInfra first lists what would change on the server and asks before
doing it. Add `-y` to skip the question.

The server runs this repo at the **same commit as your checkout**:
`deploy.py` writes the env files from your local templates, and the
server's copy supplies `docker-compose.yml`, so the two have to match.
The deploy stops before doing anything if your checkout has uncommitted
changes to tracked files, or if its commit isn't pushed to GitHub. To
deploy a different version of this repo, check it out locally first.

Reading that list: plain shell steps (installs, checkouts, builds,
checks) always count as a change, because PyInfra can't predict them;
each one skips itself when there's nothing to do. "Write the backend
.env" showing `-` means the stored secrets match what's on the server.
"Write the UI .env.local" can show `-` in the preview but still report a
change: the brainkb-ui checkout step restores the repo's committed copy
of that tracked file before pulling, and the write step then puts ours
back. The content ends up the same.

Options (`--data key=value`, repeatable):

| Option | Default | Use |
|---|---|---|
| `brainkb_branch` | `main` | Deploy a BrainKB branch |
| `ui_branch` | `main` | Deploy a brainkb-ui branch |
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
