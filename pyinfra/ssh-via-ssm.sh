#!/usr/bin/env bash
# SSH ProxyCommand for reaching an instance that has no inbound port 22.
#
#   ProxyCommand /path/to/ssh-via-ssm.sh %h %p
#
# 1. Pushes your public key to the instance with EC2 Instance Connect.
#    The key is accepted for 60 seconds, long enough to authenticate, so
#    no long-lived key has to be installed on the host.
# 2. Opens an SSM Session Manager tunnel to the instance's sshd, which
#    carries the SSH connection. No security-group rule is involved.
#
# Needs the AWS CLI with the Session Manager plugin and credentials for the
# account (e.g. AWS_PROFILE=sensein-sso). BRAINKB_SSH_KEY names the private
# key (default ~/.ssh/id_ed25519); its .pub sits next to it.
set -euo pipefail

instance_id="$1"
port="${2:-22}"
region="${AWS_REGION:-us-east-2}"
key="${BRAINKB_SSH_KEY:-$HOME/.ssh/id_ed25519}"

aws ec2-instance-connect send-ssh-public-key \
  --region "$region" \
  --instance-id "$instance_id" \
  --instance-os-user ubuntu \
  --ssh-public-key "file://${key}.pub" >/dev/null

exec aws ssm start-session \
  --region "$region" \
  --target "$instance_id" \
  --document-name AWS-StartSSHSession \
  --parameters "portNumber=${port}"
