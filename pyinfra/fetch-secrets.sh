#!/usr/bin/env bash
# Copy the env files already on the sandbox instance into pyinfra/secrets/,
# so the first PyInfra run reuses the secrets that were set up by hand.
# Ports, hostnames and Oxigraph paths in them don't matter: deploy.py
# overrides those.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
key="${BRAINKB_SSH_KEY:-$HOME/.ssh/id_ed25519}"
export BRAINKB_SSH_KEY="$key"

instance_id="$(cd "$repo/tofu/environments/sandbox" && tofu output -raw instance_id)"

mkdir -p "$here/secrets"
chmod 700 "$here/secrets"

copy() {
  scp -q -i "$key" \
    -o "ProxyCommand=$here/ssh-via-ssm.sh %h %p" \
    -o StrictHostKeyChecking=accept-new \
    "ubuntu@${instance_id}:$1" "$here/secrets/$2"
  chmod 600 "$here/secrets/$2"
  echo "Copied $1 -> pyinfra/secrets/$2"
}

copy sandbox-workspace/brainkb-infrastructure/sandbox/.env backend.env
copy sandbox-workspace/brainkb-ui/.env.local ui.env
