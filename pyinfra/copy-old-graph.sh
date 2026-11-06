#!/usr/bin/env bash
# Copy the old co-tenant sandbox's graph data (sandbox.brainkb.org, on the
# production host) into the tofu sandbox's Oxigraph (test.brainkb.org),
# by way of the FSx data bucket. Run from your laptop, in two steps:
#
#   pyinfra/copy-old-graph.sh export         # old sandbox -> S3 (read only)
#   pyinfra/copy-old-graph.sh import <name>  # S3 / FSx -> new sandbox
#
# Both talk to Oxigraph directly on each host's brainkb-sandbox-network
# (a throwaway curl container), so no Oxigraph password is needed and the
# nginx upload limits don't apply. The old sandbox is only read: the export
# is a GET of the whole store, and nothing on that host is changed or
# restarted.
#
# Needs: AWS_PROFILE=sensein-sso (or other admin credentials), tofu
# initialised in tofu/environments/sandbox, and the SSH key PyInfra uses.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
region="${AWS_REGION:-us-east-2}"
key="${BRAINKB_SSH_KEY:-$HOME/.ssh/id_ed25519}"
export BRAINKB_SSH_KEY="$key"

prod_instance_id="i-02f4d763f21e415f0" # see tofu/environments/production/imports.tf
prefix="migrations"

# Same container and network names on both hosts (sandbox/docker-compose.yml).
curl_image="curlimages/curl:8.10.1"
oxigraph="http://brainkb-oxigraph-sandbox:7878"
in_network="sudo docker run --rm -i --network brainkb-sandbox-network $curl_image -sSf"

count_query='SELECT (COUNT(*) AS ?n) WHERE { { ?s ?p ?o } UNION { GRAPH ?g { ?s ?p ?o } } }'
remote_count="$in_network -X POST -H 'Content-Type: application/sparql-query' -H 'Accept: application/sparql-results+json' --data-binary '$count_query' $oxigraph/query | grep -oE '\"value\" *: *\"[0-9]+\"' | grep -oE '[0-9]+'"

die() { echo "Error: $*" >&2; exit 1; }

tofu_out() { (cd "$repo/tofu/environments/sandbox" && tofu output -raw "$1"); }

# Production has port 22 open and no SSM agent role, so this is plain SSH
# to its public IP, with a 60-second key pushed by EC2 Instance Connect.
prod() {
  local ip
  ip="$(aws ec2 describe-instances --region "$region" --instance-ids "$prod_instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  aws ec2-instance-connect send-ssh-public-key --region "$region" \
    --instance-id "$prod_instance_id" --instance-os-user ubuntu \
    --ssh-public-key "file://${key}.pub" >/dev/null
  ssh -i "$key" -o StrictHostKeyChecking=accept-new "ubuntu@$ip" "bash -c $(printf %q "set -o pipefail; $1")"
}

# The tofu sandbox has no port 22: same SSM tunnel PyInfra uses.
sandbox() {
  local id
  id="$(tofu_out instance_id)"
  ssh -i "$key" -o StrictHostKeyChecking=accept-new \
    -o "ProxyCommand=$here/ssh-via-ssm.sh %h %p" "ubuntu@$id" \
    "bash -c $(printf %q "set -o pipefail; $1")"
}

do_export() {
  local bucket name n
  bucket="$(tofu_out data_bucket_name)"
  [ "$bucket" != "null" ] && [ -n "$bucket" ] || die "the sandbox has no FSx data bucket (enable_fsx = false?)"
  name="old-sandbox-$(date -u +%Y%m%d-%H%M%S).nq.gz"

  echo "1/3 Counting the old sandbox's graph records..."
  n="$(prod "$remote_count")"
  [[ "$n" =~ ^[0-9]+$ ]] || die "couldn't count records on the old sandbox (got: $n)"
  echo "    $n records."

  echo "2/3 Exporting them to s3://$bucket/$prefix/$name (this streams; nothing is stored on the old host)..."
  prod "$in_network -H 'Accept: application/n-quads' $oxigraph/store | gzip -1" \
    | aws s3 cp - "s3://$bucket/$prefix/$name" --region "$region"

  echo "3/3 Saving the record count next to it..."
  echo "$n" | aws s3 cp - "s3://$bucket/$prefix/$name.count" --region "$region"

  aws s3 ls "s3://$bucket/$prefix/$name" --region "$region" --human-readable
  echo
  echo "Done. Next:"
  echo "  pyinfra/copy-old-graph.sh import $name"
}

do_import() {
  local name="${1:-}" bucket expected before after file
  [ -n "$name" ] || die "usage: $0 import <name printed by export>"
  bucket="$(tofu_out data_bucket_name)"
  expected="$(aws s3 cp "s3://$bucket/$prefix/$name.count" - --region "$region")"
  file="/fsx/$prefix/$name"

  echo "1/4 Checking the new sandbox's Oxigraph is empty..."
  before="$(sandbox "$remote_count")"
  [[ "$before" =~ ^[0-9]+$ ]] || die "couldn't count records on the new sandbox (got: $before)"
  if [ "$before" != 0 ] && [ "${FORCE:-}" != 1 ]; then
    die "it already has $before records. If you've imported before, doing it again would duplicate blank nodes. If not (a few records written by the backend at startup), re-run with FORCE=1."
  fi

  echo "2/4 Waiting for the file to appear on FSx (synced from S3)..."
  sandbox "for i in \$(seq 1 30); do [ -s $file ] && exit 0; sleep 10; done; echo 'not on /fsx after 5 minutes' >&2; exit 1"

  echo "3/4 Loading $expected records (large stores can take a while)..."
  sandbox "zcat $file | $in_network -X POST -T - -H 'Content-Type: application/n-quads' $oxigraph/store"

  echo "4/4 Comparing counts..."
  after="$(sandbox "$remote_count")"
  echo "    old sandbox: $expected   new sandbox: $after"
  # Records already there that are also in the export aren't added twice,
  # so with a non-empty store anywhere from expected - before to expected
  # new records is right.
  if [ "$((after - before))" = "$expected" ]; then
    echo "Done: the counts match."
  elif [ "$after" -ge "$expected" ] && [ "$after" -le "$((before + expected))" ]; then
    echo "Done: all $expected records are there ($((before + expected - after)) of them were already in the new store)."
  else
    die "counts differ: expected $expected more records, got $((after - before))"
  fi
}

case "${1:-}" in
  export) do_export ;;
  import) shift; do_import "$@" ;;
  *) die "usage: $0 export | $0 import <name>" ;;
esac
