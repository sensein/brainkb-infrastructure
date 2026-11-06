"""PyInfra inventory for the OpenTofu-managed sandbox.

The host comes from `tofu output` in tofu/environments/sandbox, so this
always targets whatever instance tofu currently manages. Run pyinfra from
anywhere inside the repo, with AWS credentials for the account and tofu
initialised in that directory.

PyInfra treats every module-level list in this file as a host group, so
everything except `sandbox` is prefixed with an underscore.
"""

import json
import os
import subprocess
from pathlib import Path

_REPO_ROOT = Path(
    subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
)
_HERE = _REPO_ROOT / "pyinfra"

_outputs = json.loads(
    subprocess.run(
        ["tofu", "output", "-json"],
        cwd=_REPO_ROOT / "tofu" / "environments" / "sandbox",
        check=True,
        capture_output=True,
        text=True,
    ).stdout
)
_instance_id = _outputs["instance_id"]["value"]
_public_hostname = _outputs["app_hostnames"]["value"][0]  # test.brainkb.org
# Both null when the sandbox runs without FSx (enable_fsx = false).
_fsx_dns_name = _outputs["pyinfra"]["value"]["fsx_dns_name"]
_fsx_mount_name = _outputs["pyinfra"]["value"]["fsx_mount_name"]

_ssh_key = os.path.expanduser(os.environ.get("BRAINKB_SSH_KEY", "~/.ssh/id_ed25519"))
# The ProxyCommand script inherits this to find the matching .pub.
os.environ["BRAINKB_SSH_KEY"] = _ssh_key

# Generated, not committed: it embeds this checkout's absolute paths.
_ssh_config = _HERE / ".ssh_config"
_ssh_config.write_text(
    f"Host {_instance_id}\n"
    f"  User ubuntu\n"
    f"  IdentityFile {_ssh_key}\n"
    f"  ProxyCommand {_HERE / 'ssh-via-ssm.sh'} %h %p\n"
)

sandbox = [
    (
        _instance_id,
        {
            "ssh_user": "ubuntu",
            "ssh_key": _ssh_key,
            "ssh_config_file": str(_ssh_config),
            "repo_root": str(_REPO_ROOT),
            "public_hostname": _public_hostname,
            "fsx_dns_name": _fsx_dns_name,
            "fsx_mount_name": _fsx_mount_name,
        },
    )
]
