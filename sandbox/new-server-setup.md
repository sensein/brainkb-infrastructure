# Setting up the OpenTofu sandbox server

How to install BrainKB on the dedicated sandbox server that
`tofu/environments/sandbox/` builds. This is a separate machine from
production, and it's reached at the `test.brainkb.org` names. The
co-tenant sandbox on production's EC2 (`sandbox.brainkb.org`, described
in `README.md` and `notes.md`) is a different deployment and keeps
running unchanged.

Written 2026-11-02 and walked through by hand the same day. Steps 2–6
are automated in `../pyinfra/` (`pyinfra pyinfra/inventory.py
pyinfra/deploy.py`); this file stays as the explanation of what that
does, and the fallback for doing it by hand.

## How this differs from the co-tenant sandbox

| | Co-tenant sandbox (`README.md`) | This server |
|---|---|---|
| Host | Production's EC2 | Its own EC2 (`brainkb-sandbox`, `t3.medium`) |
| Hostnames | `*.sandbox.brainkb.org` | `test.brainkb.org`, `usermanagement.test.brainkb.org`, `mlservice.test.brainkb.org`, `queryservice.test.brainkb.org` |
| Ports | +10000 (13000, 18000, 18004, 18007, 18010) | Production's own (3000, 8000, 8004, 8007, 8010) |
| Load balancer | `sandbox-alb`, built by hand | `brainkb-sandbox-alb`, managed by OpenTofu |
| Login | SSH | SSM Session Manager only. No port 22 is open. |
| Inbound traffic | Several ports open | Only 3000, 8004, 8007 and 8010, and only from the load balancer |
| Query service | Browsers call the host's IP on port 18010 | Behind the load balancer at `queryservice.test.brainkb.org` (#14, following `decisions.md` §7) |

The compose file and both env templates in this directory are reused.
Only the values change.

## 0. Before you start

- AWS SSO login for account `164409279158` (the `sensein-sso` profile)
  and the Session Manager plugin on your laptop
  (`brew install --cask session-manager-plugin`).
- The instance ID, from `tofu output instance_id` in
  `tofu/environments/sandbox/`. It was `i-008a0c667a85dd0f4` at first
  apply. It only changes if the instance is replaced.
- Real values for the secrets in `backend.env.template` and
  `ui.env.template` (passwords, JWT secrets, API keys). The co-tenant
  sandbox's `.env` files on production's EC2 are the nearest source.
  Copy the secrets only, not the ports or hostnames.

## 1. Log in to the server

From your laptop:

```
aws sso login --profile sensein-sso
export AWS_PROFILE=sensein-sso
aws ssm start-session --target i-008a0c667a85dd0f4 --region us-east-2
```

SSM logs you in as `ssm-user`. Switch to `ubuntu` so files and
processes have a stable owner:

```
sudo su - ubuntu
```

Everything below runs as `ubuntu` on the server.

## 2. Install Docker

```
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 git
sudo usermod -aG docker ubuntu
```

Log out of the `ubuntu` shell and back in (`exit`, then
`sudo su - ubuntu`) so the group change applies. Then check:

```
docker version
docker compose version
```

If `docker-compose-v2` isn't available from apt, install Docker from
Docker's own apt repository instead
(https://docs.docker.com/engine/install/ubuntu/).

## 3. Install Node.js and PM2 (for the UI)

`brainkb-ui/bin/up-node.sh` needs Node 18.18 or newer. Install Node 20
with nvm, so global npm installs don't need sudo:

```
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
source ~/.nvm/nvm.sh
nvm install 20
npm install -g pm2
node -v && pm2 -v
```

## 4. Get the code

All three repositories are public, so no GitHub credentials are needed.
Use the same sibling layout as production, which is what the compose
file's `BACKEND_REPO_PATH` default expects:

```
mkdir -p ~/sandbox-workspace && cd ~/sandbox-workspace
git clone https://github.com/sensein/brainkb-infrastructure.git
git clone https://github.com/sensein/BrainKB.git
git clone https://github.com/sensein/brainkb-ui.git
```

Check out the branches you want to test in `BrainKB` and `brainkb-ui`.

## 5. Backend

```
docker network create brainkb-sandbox-network
cd ~/sandbox-workspace/brainkb-infrastructure/sandbox
cp backend.env.template .env
```

Switch the service ports back to production's. The template has the
co-tenant +10000 values, and the load balancer here forwards to 8004 and
8007:

```
sed -i \
  -e 's/^API_TOKEN_PORT=.*/API_TOKEN_PORT=8000/' \
  -e 's/^QUERY_SERVICE_PORT=.*/QUERY_SERVICE_PORT=8010/' \
  -e 's/^ML_SERVICE_PORT=.*/ML_SERVICE_PORT=8007/' \
  -e 's/^USERMANAGEMENT_SERVICE_PORT=.*/USERMANAGEMENT_SERVICE_PORT=8004/' \
  -e 's/^UI_PORT=.*/UI_PORT=3000/' \
  -e 's#^USERMANAGEMENT_PUBLIC_BASE_URL=.*#USERMANAGEMENT_PUBLIC_BASE_URL=https://usermanagement.test.brainkb.org#' \
  -e 's#^USERMANAGEMENT_FRONTEND_CALLBACK_URL=.*#USERMANAGEMENT_FRONTEND_CALLBACK_URL=https://test.brainkb.org/auth/callback#' \
  .env
grep -E '^(API_TOKEN|QUERY_SERVICE|ML_SERVICE|USERMANAGEMENT_SERVICE|UI)_PORT=|^USERMANAGEMENT_(PUBLIC_BASE|FRONTEND_CALLBACK)_URL=|^CORS_ALLOWED_ORIGINS=' .env
```

The last command should show the five ports, both `test.*` URLs, and
`CORS_ALLOWED_ORIGINS=https://test.brainkb.org`. That line comes from
the template (PR #11), and without it the backend refuses browser calls
from the new UI. `POSTGRES_HOST_PORT`, `PGADMIN_PORT` and
`OXIGRAPH_PORT` can keep their 15432/15051/17878 defaults. Nothing
outside the server can reach them.

Then fill in the secrets (`nano .env`), leave `OXIGRAPH_DATA_PATH` and
`OXIGRAPH_TMP_PATH` blank, and start the stack:

```
docker compose up -d --build
docker exec brainkb-unified-sandbox supervisorctl status
```

All four services (`api_tokenmanager`, `query_service`, `ml_service`,
`usermanagement_service`) should show `RUNNING`, and still show it a
minute later.

## 6. Frontend

```
cd ~/sandbox-workspace/brainkb-ui
cp ../brainkb-infrastructure/sandbox/ui.env.template .env.local
sed -i \
  -e 's/sandbox\.brainkb\.org/test.brainkb.org/g' \
  -e 's#http://<host>:18010#https://queryservice.test.brainkb.org#g' \
  -e 's/^PORT=.*/PORT=3000/' \
  .env.local
grep -n 'brainkb.org\|^PORT=' .env.local
```

The `sed` turns every `sandbox.brainkb.org` into `test.brainkb.org`
(`usermanagement.sandbox.` becomes `usermanagement.test.`, and so on),
including `NEXTAUTH_URL`, and points the query-service lines at
`https://queryservice.test.brainkb.org` (the load-balancer route from
#14). Fill in
`NEXTAUTH_SECRET` and the other blank values. The chat-service lines
still say `<host>`; chat_service is unused, so leave them.

`.env.local` is a tracked file in `brainkb-ui` (see `README.md`), so
`git status` will show it as modified. That's expected.

Build and start it under PM2:

```
PM2_APP_NAME=brainkb-ui-sandbox PORT=3000 bash bin/up-node.sh
pm2 startup    # prints a sudo command; run it so PM2 restarts on reboot
pm2 save
```

## 7. Check it through the load balancer

From your laptop, in `tofu/environments/sandbox/`:

```
ALB=$(tofu output -raw alb_dns_name)
curl -k -sI -H "Host: test.brainkb.org" "https://$ALB/"
curl -k -sI -H "Host: usermanagement.test.brainkb.org" "https://$ALB/"
curl -k -sI -H "Host: mlservice.test.brainkb.org" "https://$ALB/"
curl -k -sI -H "Host: queryservice.test.brainkb.org" "https://$ALB/"
```

Before the apps were installed, these returned `502` (the load balancer
was up but nothing answered behind it). Now the first should return
`200`. For the others, any real response (`200`, `404`, `405`) means
the request reached the service. `-k` is needed because the certificate
is for `test.brainkb.org`, not the load balancer's own AWS name.

Target health is in the AWS console (EC2 → Target Groups →
`brainkb-sandbox-ui`, `-usermgmt`, `-mlservice`, `-queryservice` → Targets). The health
check requests `/` and expects 200–299, so a service that answers `/`
with 404 shows as unhealthy even when it's working. The load balancer
still forwards traffic when every target is unhealthy, so this is
cosmetic. Fix it by setting `health_check_path` in `sandbox.tfvars` once
each service's health endpoint is known.

## 8. Go live on `test.brainkb.org`

When the team wants the `test.*` names public, open a PR that sets
`create_app_dns_records = true` in `tofu/environments/sandbox/sandbox.tfvars`.
After it merges:

```
tofu plan -var-file=sandbox.tfvars    # expect 4 to add, 0 to change, 0 to destroy
tofu apply -var-file=sandbox.tfvars
curl -sI https://test.brainkb.org/
```

The four additions are the A records for the `test.*` names. If the
plan shows anything else, stop and check before applying.

Logging in on the UI also needs the OAuth providers (GitHub, ORCID,
Globus) to accept the new callback URL,
`https://usermanagement.test.brainkb.org/api/auth/<provider>/callback`.
That's set in each provider's app settings, not in this repo.

## Known gaps

- **Disk space.** The `brainkb-unified` image is large: it pulls in
  several GB of NVIDIA/CUDA Python libraries even though this server has
  no GPU, and the first build briefly needs room for both the packed and
  the unpacked layers. The original 30 GB disk ran out ("no space left on
  device"), so the recipe now sets 100 GB. After an `apply` that grows
  the disk, make the filesystem use the new space on the server:
  `sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1`, then
  check with `df -h /`. Run `docker builder prune -af` after a failed
  build to reclaim what it used.
- **Memory.** `t3.medium` has 4 GB of RAM. Production reserves 16 GB for
  the backend container, and `npm run build` needs around 2 GB on its
  own. If builds or services get killed (`dmesg | grep -i oom`, or
  services stuck in `BACKOFF`), raise `instance_type` in
  `sandbox.tfvars` to `t3.large` (8 GB) or `t3.xlarge` (16 GB). The
  change is in place: the instance stops and starts again with its disk
  intact. The cost goes up with the size.
- **Oxigraph starts empty**, the same as the co-tenant sandbox. See
  "Still open: loading data into Oxigraph" in `README.md`.
- **MCP and Ollama aren't covered here.** Fix the shared container and
  image names first (see the MCP warning in `README.md` and `notes.md`)
  before deploying MCP anywhere.
