#!/usr/bin/env python3
"""Store sandbox secrets in SSM Parameter Store, where deploy.py reads them.

Each key becomes one SecureString parameter:
/brainkb/sandbox/<kind>/<KEY>, where <kind> is "backend" or "ui".
--prefix changes /brainkb/sandbox, matching deploy.py's ssm_prefix.

    # Load every non-empty KEY=value line from an env file:
    pyinfra/push-secrets.py backend pyinfra/secrets/backend.env
    pyinfra/push-secrets.py ui pyinfra/secrets/ui.env

    # Set or change one value; you're prompted for it, so it stays out of
    # your shell history:
    pyinfra/push-secrets.py backend --set GLOBUS_CLIENT_SECRET

    # See what's stored (names only, never values):
    pyinfra/push-secrets.py backend --list

    # Remove a key (asks first):
    pyinfra/push-secrets.py backend --delete MONGO_DB_URL

Uses the AWS CLI with your current credentials (e.g. AWS_PROFILE=sensein-sso).
Only key names are printed.
"""

import argparse
import getpass
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_PREFIX = "/brainkb/sandbox"
REGION = os.environ.get("AWS_REGION", "us-east-2")


def aws(*args):
    result = subprocess.run(
        ["aws", *args, "--region", REGION],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # Show the CLI's own message (expired login, access denied, bad
        # input). It goes to your terminal only.
        sys.exit(f"aws {' '.join(args[:2])} failed (exit {result.returncode}):\n{result.stderr.strip()}")
    return result.stdout


def put(prefix, kind, key, value):
    # The value goes in through a private temporary file rather than as a
    # command-line argument, so it doesn't show up in the process list.
    request = {
        "Name": f"{prefix}/{kind}/{key}",
        "Value": value,
        "Type": "SecureString",
        "Overwrite": True,
    }
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "request.json"
        path.touch(mode=0o600)
        path.write_text(json.dumps(request))
        aws("ssm", "put-parameter", "--cli-input-json", f"file://{path}")


def read_env(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            values[key.strip()] = value
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kind", choices=["backend", "ui"])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("env_file", nargs="?", help="env file to load (KEY=value lines)")
    group.add_argument("--set", metavar="KEY", help="set one key; prompts for the value")
    group.add_argument("--list", action="store_true", help="list stored key names")
    group.add_argument("--delete", metavar="KEY", help="delete one key; asks first")
    parser.add_argument("--prefix", default=DEFAULT_PREFIX,
                        help=f"parameter path prefix (default {DEFAULT_PREFIX})")
    args = parser.parse_args()
    PREFIX = args.prefix.rstrip("/")

    if args.list:
        names = json.loads(
            aws(
                "ssm", "get-parameters-by-path",
                "--path", f"{PREFIX}/{args.kind}/",
                "--recursive",
                "--query", "Parameters[].Name",
                "--output", "json",
            )
        )
        for name in sorted(names):
            print(name.rsplit("/", 1)[1])
        return

    if args.delete:
        name = f"{PREFIX}/{args.kind}/{args.delete}"
        if input(f"Delete {name}? [y/N] ").strip().lower() not in ("y", "yes"):
            sys.exit("Nothing deleted.")
        aws("ssm", "delete-parameter", "--name", name)
        print(f"Deleted {name}")
        return

    if args.set:
        value = getpass.getpass(f"Value for {args.set}: ")
        if not value:
            sys.exit("Empty value; nothing stored.")
        put(PREFIX, args.kind, args.set, value)
        print(f"Stored {PREFIX}/{args.kind}/{args.set}")
        return

    values = read_env(args.env_file)
    # SSM doesn't allow empty values; a missing key renders as the
    # template's blank default anyway.
    skipped = sorted(key for key, value in values.items() if not value)
    for key, value in values.items():
        if value:
            put(PREFIX, args.kind, key, value)
            print(f"Stored {PREFIX}/{args.kind}/{key}")
    if skipped:
        print(f"Skipped {len(skipped)} empty keys: {', '.join(skipped)}")


if __name__ == "__main__":
    main()
