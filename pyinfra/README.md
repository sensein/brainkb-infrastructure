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

2. AWS access: the AWS CLI (`brew install awscli`), the Session Manager
   plugin (`brew install --cask session-manager-plugin`), and an SSO
   login for account 164409279158.

   `sensein-sso` in the commands here is the name of an AWS CLI
   **profile**, an entry in your own `~/.aws/config`. It isn't an
   account or a shared setting, so create it once:

       aws configure sso

   When asked, give:
   - SSO start URL: `https://mit.awsapps.com/start`
   - the region it asks for
   - account: `164409279158`
   - role: `AdministratorAccess` (or whichever your login offers for that account)
   - default region: `us-east-2`
   - profile name: `sensein-sso`. Any name works; this one matches the commands here.

   Then, in each new terminal:

       aws sso login --profile sensein-sso
       export AWS_PROFILE=sensein-sso

   Check it with `aws sts get-caller-identity`: it should show account
   164409279158 and an `AWSReservedSSO_...` role. If it shows an IAM user
   (`user/<name>`) instead, the profile isn't in use, and connecting fails
   with `not authorized to perform: ec2-instance-connect:SendSSHPublicKey`.

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
    pyinfra/push-secrets.py backend --delete SOME_KEY          # asks first

Then re-run the deploy (`--data build_ui=false` if only backend values
changed)). A key that's in SSM but not in the template is still written to
the server (at the end of the file), so delete keys that are no longer
used rather than leaving them. Avoid `aws ssm put-parameter --value ...` for secrets: it leaves
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
If your branch is behind its copy on GitHub (usually a forgotten
`git pull`), it says by how many commits and asks before deploying the
older version.

Reading that list: plain shell steps (installs, checkouts, builds,
checks) always count as a change, because PyInfra can't predict them;
each one skips itself when there's nothing to do. "Write the backend
.env" showing `-` means the stored secrets match what's on the server.
"Write the UI .env.local" can show `-` in the preview but still report a
change: the brainkb-ui checkout step restores the repo's committed copy
of that tracked file before pulling, and the write step then puts ours
back. The content ends up the same.

**Don't print secrets.** Run the deploy without `--diff`: with it,
PyInfra prints the changes to the env files, secret values included. On
the server, `docker compose config`, `docker inspect` and `cat .env`
also show them. Don't paste their output into chat, issues or Slack
when debugging; share key names instead.

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

## FSx for Lustre

When the sandbox has FSx (`enable_fsx = true` in
`tofu/environments/sandbox/sandbox.tfvars`), `inventory.py` picks up its
DNS and mount names from `tofu output`, and the deploy:

1. adds AWS's FSx Lustre client apt repository,
2. installs `lustre-client-modules-$(uname -r)`, the client built for the
   **running kernel**,
3. mounts the file system at `/fsx` (with an `/etc/fstab` entry, so it
   comes back after a reboot), and
4. installs a nightly backup of the graph store to `/fsx/backups/`
   (see "Graph backups" below).

Oxigraph's live data is on the server's own disk, at
`/home/ubuntu/oxigraph-db`, with or without FSx. Nothing in Docker
depends on `/fsx`, so a missing FSx mount only stops backups. Earlier
deploys put the data on `/fsx/oxigraph-db`. The first deploy after the
change moves it:

1. counts the records (`brainkb-graph-count`, installed by the deploy),
2. stops Oxigraph and copies the store to `/home/ubuntu/oxigraph-db.partial`,
3. renames that to `oxigraph-db` only once the copy has finished (a
   failed copy stops the deploy and switches nothing), and
4. after compose starts Oxigraph on the local copy, compares the count
   and fails the deploy if it differs.

The FSx copy is left in place. Once the local copy is confirmed, remove
it from both FSx and S3; the S3 link doesn't export deletes:

    sudo rm -r /fsx/oxigraph-db
    aws s3 rm --recursive s3://sensein-brainkb-sandbox-data/oxigraph-db/

Its old S3 versions expire after 30 days.

The Lustre client is a kernel module, so its version has to match the
kernel. The deploy installs two packages:

- `lustre-client-modules-$(uname -r)`, for the kernel running now. If
  AWS hasn't published a build for it yet, the step stops with a message
  saying so, before anything is mounted.
- `lustre-client-modules-aws`, which follows Ubuntu's `linux-aws` kernel
  package. When Ubuntu installs a kernel update on its own, the matching
  Lustre module comes with it, so `/fsx` still mounts after the reboot.

A last check looks at the newest installed kernel, the one the next
reboot will use, and stops if it has no Lustre module. If that happens,
don't reboot; re-run the deploy once AWS has published the module.

### Graph backups

`/usr/local/bin/brainkb-graph-backup` runs every night at 03:17 UTC
(`/etc/cron.d/brainkb-graph-backup`). It:

- exports the whole store (`GET /store`, gzipped N-Quads), which Oxigraph
  serves from a consistent snapshot without stopping,
- writes `/fsx/backups/graph-<date>.nq.gz` through a local temp file, so
  a failed export never lands on FSx (the move to FSx is a copy, which
  the S3 link may see partway; its final export is the finished file), and
- keeps the newest 7 on FSx.

The FSx ↔ S3 link copies each file to `s3://sensein-brainkb-sandbox-data/backups/`.
It doesn't export deletes, so S3 keeps older ones until someone removes
them (see #24). The script stops with a message if FSx isn't mounted.
Its log is `/var/log/brainkb-graph-backup.log`.

To run it by hand: `sudo /usr/local/bin/brainkb-graph-backup`.

**After the first deploy with backups, check them once,** on the server:

1. Run the backup by hand, then confirm the file is on FSx and in S3:

       sudo /usr/local/bin/brainkb-graph-backup
       ls -lh /fsx/backups/
       aws s3 ls s3://sensein-brainkb-sandbox-data/backups/   # from a laptop with AWS access

2. Restore it into a spare Oxigraph and compare counts. This leaves the
   live store alone:

       f=$(ls -1t /fsx/backups/graph-*.nq.gz | head -n 1)
       sudo mkdir -p /var/tmp/restore-test
       zcat "$f" | sudo docker run --rm -i -v /var/tmp/restore-test:/data ghcr.io/oxigraph/oxigraph:latest load --location /data --format nq
       sudo docker run -d --name oxigraph-restore-test --network brainkb-sandbox-network -v /var/tmp/restore-test:/data ghcr.io/oxigraph/oxigraph:latest serve --location /data --bind 0.0.0.0:7878
       sleep 10; brainkb-graph-count oxigraph-restore-test; brainkb-graph-count
       sudo docker rm -f oxigraph-restore-test && sudo rm -r /var/tmp/restore-test

   The two counts should match (23,472,446 at the 2026-11-06 copy, plus
   anything added since).

To restore for real, load a file the same way into the live store's
directory with Oxigraph stopped, as `copy-old-graph.sh import` does (#20).

## How it connects

The sandbox instance has no inbound SSH port (by design; see the tofu
sandbox README). `ssh-via-ssm.sh` is used as the SSH `ProxyCommand`. It:

1. pushes your public key to the instance with **EC2 Instance Connect**
   (valid for 60 seconds, so no permanent key is installed on the
   server), then
2. opens an **SSM Session Manager** tunnel to the instance's sshd and
   carries the SSH connection over it.

`inventory.py` writes `pyinfra/.ssh_config` (gitignored) with this set up,
so it exists only after one `pyinfra pyinfra/inventory.py ...` run. Plain
`ssh` to the instance (without that file) can't connect: there's no
port 22. With the file, and `AWS_PROFILE` set, you can use it for a
normal shell too:

    ssh -F pyinfra/.ssh_config "$(cd tofu/environments/sandbox && tofu output -raw instance_id)"

Without the repo set up, a shell needs only the AWS CLI, the plugin and
the profile:

    aws ssm start-session --profile sensein-sso --region us-east-2 --target "$(cd tofu/environments/sandbox && tofu output -raw instance_id)"

(or the instance ID, `i-008a0c667a85dd0f4` today), then `sudo su - ubuntu`.
The console's **Session Manager** tab works too; its **EC2 Instance
Connect** tab doesn't, because it needs port 22.

This is option 2 ("SSM-based execution") of `decisions.md` §5.

## Not covered

- Creating the server itself: that's `tofu apply`.
- OAuth callback URLs at GitHub/ORCID/Globus.
- Loading data into Oxigraph, MCP, Ollama, and production.
