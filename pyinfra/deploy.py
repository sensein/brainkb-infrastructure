"""Install and start BrainKB on the OpenTofu-managed sandbox instance.

The automated version of sandbox/new-server-setup.md, steps 2-6: swap,
Docker, Node/PM2, the three repos, both env files, the backend stack and
the UI. Safe to re-run: each step skips what's already in place, so the
same command also deploys new code.

Usage (from anywhere in the repo; see pyinfra/README.md):

    pyinfra pyinfra/inventory.py pyinfra/deploy.py
    pyinfra pyinfra/inventory.py pyinfra/deploy.py --data brainkb_branch=my-branch
    pyinfra pyinfra/inventory.py pyinfra/deploy.py --data build_ui=false
"""

import io
import re
import subprocess
import sys
from pathlib import Path

from pyinfra import host
from pyinfra.operations import apt, files, server

REPO_ROOT = Path(host.data.repo_root)
SECRETS = REPO_ROOT / "pyinfra" / "secrets"
HOSTNAME = host.data.public_hostname  # test.brainkb.org

WORKSPACE = "/home/ubuntu/sandbox-workspace"
INFRA_DIR = f"{WORKSPACE}/brainkb-infrastructure"
BACKEND_DIR = f"{WORKSPACE}/BrainKB"
UI_DIR = f"{WORKSPACE}/brainkb-ui"



def local_commit():
    """The commit this checkout is on, which the server then checks out too.

    deploy.py and the env templates are read from this checkout, while the
    compose file is used from the server's. Pinning the server to the same
    commit keeps them in step, so the deploy stops if that commit can't be
    reproduced there: uncommitted changes to tracked files, or a commit
    that isn't on GitHub yet.
    """
    def git(*args):
        return subprocess.run(["git", "-C", str(REPO_ROOT), *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    if git("status", "--porcelain", "--untracked-files=no"):
        raise SystemExit(
            "This checkout has uncommitted changes. Commit and push them (or stash them) "
            "first, so the server runs the same files as this deploy."
        )
    commit = git("rev-parse", "HEAD")
    git("fetch", "--quiet", "origin")
    if not git("branch", "--remotes", "--contains", commit):
        raise SystemExit(
            f"Commit {commit[:12]} isn't on GitHub yet. Push it first, so the server "
            "can check out the same commit as this deploy."
        )

    # Pushed but out of date: the usual cause is a forgotten `git pull`,
    # which would put the server back on an older version. Ask first.
    try:
        upstream = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    except subprocess.CalledProcessError:
        upstream = None  # detached HEAD or no tracking branch: nothing to compare
    if upstream:
        behind = int(git("rev-list", "--count", f"HEAD..{upstream}"))
        if behind:
            print(
                f"Your checkout is {behind} commit{'s' if behind > 1 else ''} behind "
                f"{upstream} (run `git pull` to update)."
            )
            if not sys.stdin.isatty():
                raise SystemExit("Stopping: can't ask whether to continue without a terminal.")
            if input("Deploy this older version anyway? [y/N] ").strip().lower() not in ("y", "yes"):
                raise SystemExit("Stopped. Nothing was changed on the server.")
    return commit


INFRA_COMMIT = local_commit()

REPOS = [
    ("https://github.com/sensein/brainkb-infrastructure.git", INFRA_DIR, INFRA_COMMIT),
    ("https://github.com/sensein/BrainKB.git", BACKEND_DIR, host.data.get("brainkb_branch", "main")),
    ("https://github.com/sensein/brainkb-ui.git", UI_DIR, host.data.get("ui_branch", "main")),
]

BUILD_UI = str(host.data.get("build_ui", True)).lower() not in ("false", "0", "no")

# Values that differ from the co-tenant sandbox the templates were written
# for. They're applied last, so they win over anything in the secrets files
# (which may be copies of the co-tenant .env files).
BACKEND_SETTINGS = {
    "API_TOKEN_PORT": "8000",
    "QUERY_SERVICE_PORT": "8010",
    "ML_SERVICE_PORT": "8007",
    "USERMANAGEMENT_SERVICE_PORT": "8004",
    "UI_PORT": "3000",
    "USERMANAGEMENT_PUBLIC_BASE_URL": f"https://usermanagement.{HOSTNAME}",
    "USERMANAGEMENT_FRONTEND_CALLBACK_URL": f"https://{HOSTNAME}/auth/callback",
    "CORS_ALLOWED_ORIGINS": f"https://{HOSTNAME}",
    # Blank = Docker named volumes. The co-tenant .env points these at
    # host directories that don't exist on this instance.
    "OXIGRAPH_DATA_PATH": "",
    "OXIGRAPH_TMP_PATH": "",
}
UI_SETTINGS = {
    "NEXTAUTH_URL": f"https://{HOSTNAME}",
    "PM2_APP_NAME": "brainkb-ui-sandbox",
    "PORT": "3000",
}


def read_env(path):
    """KEY=value pairs from an env file; comments and blank lines skipped."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value
    return values


def render_env(template, values):
    """Fill `values` into the template's KEY= lines, keeping its comments and
    order. Keys the template doesn't have are appended at the end."""
    out, used = [], set()
    for line in template.splitlines():
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if match and match.group(1) in values:
            key = match.group(1)
            out.append(f"{key}={values[key]}")
            used.add(key)
        else:
            out.append(line)
    extra = [key for key in values if key not in used]
    if extra:
        out += ["", "# ---- Not in the template (from pyinfra/secrets) ----"]
        out += [f"{key}={values[key]}" for key in extra]
    return "\n".join(out) + "\n"


def load_secrets(name):
    path = SECRETS / name
    if not path.exists():
        raise RuntimeError(
            f"{path} is missing. Create it before deploying; see pyinfra/README.md, 'Secrets'."
        )
    return read_env(path)


backend_values = {**load_secrets("backend.env"), **BACKEND_SETTINGS}
backend_env = render_env((REPO_ROOT / "sandbox" / "backend.env.template").read_text(), backend_values)

ui_secrets = load_secrets("ui.env")
if not ui_secrets.get("NEXTAUTH_SECRET"):
    raise RuntimeError("NEXTAUTH_SECRET is empty in pyinfra/secrets/ui.env. Generate one with: openssl rand -base64 32")
ui_template = (
    (REPO_ROOT / "sandbox" / "ui.env.template")
    .read_text()
    .replace("http://<host>:18010", f"https://queryservice.{HOSTNAME}")
    .replace("sandbox.brainkb.org", HOSTNAME)
)
ui_env = render_env(ui_template, {**ui_secrets, **UI_SETTINGS})


# ---- Host basics -----------------------------------------------------------

server.shell(
    name="Create and enable a 4 GB swap file",
    commands=[
        "test -f /swapfile || (fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile)",
        "swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile",
    ],
    _sudo=True,
)
files.line(
    name="Keep the swap file across reboots",
    path="/etc/fstab",
    line="/swapfile none swap sw 0 0",
    _sudo=True,
)

apt.packages(
    name="Install Docker, Compose and git",
    packages=["docker.io", "docker-compose-v2", "git"],
    update=True,
    cache_time=3600,
    _sudo=True,
)
server.user(
    name="Add ubuntu to the docker group",
    user="ubuntu",
    groups=["docker"],
    append=True,
    _sudo=True,
)

server.shell(
    name="Install nvm, Node 20 and PM2",
    commands=[
        "test -s $HOME/.nvm/nvm.sh || curl -fsSo- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash",
        "bash -c '. $HOME/.nvm/nvm.sh && nvm install 20 >/dev/null && (command -v pm2 >/dev/null || npm install -g pm2)'",
    ],
)

# ---- Code ------------------------------------------------------------------

for url, path, branch in REPOS:
    commands = [f"test -d {path}/.git || git clone --quiet {url} {path}"]
    if path == UI_DIR:
        # .env.local is tracked in brainkb-ui. Put the committed copy back
        # before pulling so a pull can't conflict with ours; ours is
        # written again below.
        commands.append(f"cd {path} && (git checkout -- .env.local 2>/dev/null || true)")
    if path == INFRA_DIR:
        # A commit, not a branch: the one this deploy is running from.
        commands.append(f"cd {path} && git fetch --quiet origin && git checkout --quiet --detach {branch}")
        label = branch[:12]
    else:
        commands.append(
            f"cd {path} && git fetch --quiet origin && git checkout --quiet {branch} "
            f"&& git pull --quiet --ff-only origin {branch}"
        )
        label = branch
    server.shell(name=f"Check out {Path(path).name} at {label}", commands=commands)

# ---- Settings --------------------------------------------------------------

files.put(
    name="Write the backend .env",
    src=io.StringIO(backend_env),
    dest=f"{INFRA_DIR}/sandbox/.env",
    mode="600",
)
files.put(
    name="Write the UI .env.local",
    src=io.StringIO(ui_env),
    dest=f"{UI_DIR}/.env.local",
    mode="600",
)

# ---- Backend ---------------------------------------------------------------
# Docker commands run under sudo: the docker group change above only takes
# effect in new login sessions.

server.shell(
    name="Create the brainkb-sandbox-network Docker network",
    commands=[
        "docker network inspect brainkb-sandbox-network >/dev/null 2>&1 "
        "|| docker network create brainkb-sandbox-network"
    ],
    _sudo=True,
)
server.shell(
    name="Build and start the backend stack",
    commands=[f"cd {INFRA_DIR}/sandbox && docker compose up -d --build"],
    _sudo=True,
)
server.shell(
    name="Wait for all backend services to be RUNNING",
    # supervisord's own oxigraph program is autostart=false; the compose
    # stack runs Oxigraph in its own container.
    commands=[
        "for i in $(seq 1 30); do "
        "out=$(docker exec brainkb-unified-sandbox supervisorctl status 2>/dev/null || true); "
        'if [ -n "$out" ] && ! echo "$out" | grep -v "^oxigraph " | grep -qv RUNNING; '
        'then echo "$out"; exit 0; fi; '
        "sleep 10; done; "
        'echo "$out"; exit 1'
    ],
    _sudo=True,
)

# ---- UI --------------------------------------------------------------------

if BUILD_UI:
    server.shell(
        name="Build and (re)start the UI under PM2",
        commands=[
            f"bash -c '. $HOME/.nvm/nvm.sh && cd {UI_DIR} && "
            f"PM2_APP_NAME=brainkb-ui-sandbox PORT=3000 bash bin/up-node.sh'"
        ],
    )

server.shell(
    name="Restart PM2 processes on reboot",
    commands=[
        "bash -c '. $HOME/.nvm/nvm.sh && "
        "sudo env PATH=$PATH pm2 startup systemd -u ubuntu --hp /home/ubuntu >/dev/null && pm2 save'"
    ],
)
server.shell(
    name="Check the UI answers on port 3000",
    commands=[
        "for i in $(seq 1 30); do "
        '[ "$(curl -s -o /dev/null -w %{http_code} http://localhost:3000/)" = 200 ] && exit 0; '
        "sleep 5; done; exit 1"
    ],
)
