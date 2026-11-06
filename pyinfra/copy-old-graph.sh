#!/usr/bin/env bash
# Copy the old co-tenant sandbox's graph data (sandbox.brainkb.org, on the
# production host) into the tofu sandbox's Oxigraph (test.brainkb.org),
# by way of the FSx data bucket. Run from your laptop, in two steps:
#
#   pyinfra/copy-old-graph.sh export         # old sandbox -> S3 (read only)
#   pyinfra/copy-old-graph.sh import <name>  # S3 / FSx -> new sandbox
#
# The app's Postgres database (users, spaces and which graphs belong to
# them, permissions, jobs) is separate and copied in one step:
#
#   pyinfra/copy-old-graph.sh postgres       # replaces the new sandbox's DB
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

  # Oxigraph's offline bulk loader, not a POST to /store: a POST loads in
  # one transaction held in memory, which a 4 GB instance can't do for
  # millions of records. The loader needs the database to itself, so
  # Oxigraph is stopped while it runs (graph queries on the sandbox fail
  # meanwhile) and started again afterwards, even if the load fails.
  # --non-atomic writes as it goes, which keeps memory and disk use down.
  # optimize then compacts the store for faster reads, as the loader advises.
  echo "3/4 Loading $expected records with Oxigraph stopped (large stores can take a while)..."
  sandbox "ctr=brainkb-oxigraph-sandbox
    data=\$(sudo docker inspect \$ctr --format '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{.Source}}{{end}}{{end}}')
    image=\$(sudo docker inspect \$ctr --format '{{.Config.Image}}')
    [ -n \"\$data\" ] || { echo 'no /data mount on the Oxigraph container' >&2; exit 1; }
    sudo docker stop \$ctr >/dev/null
    zcat $file | sudo docker run --rm -i -v \"\$data\":/data \"\$image\" load --location /data --format nq --non-atomic --lenient &&
      sudo docker run --rm -v \"\$data\":/data \"\$image\" optimize --location /data
    status=\$?
    sudo docker start \$ctr >/dev/null
    exit \$status"

  echo "4/4 Comparing counts..."
  after=""
  for _ in $(seq 1 30); do # Oxigraph takes a moment to open the store
    after="$(sandbox "$remote_count" 2>/dev/null || true)"
    [[ "$after" =~ ^[0-9]+$ ]] && break
    sleep 5
  done
  [[ "$after" =~ ^[0-9]+$ ]] || die "Oxigraph didn't answer after the load; check: sudo docker logs brainkb-oxigraph-sandbox"
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

# Postgres: pg_dump of the old sandbox's app database (read only), via S3
# so a copy is kept, then pg_restore --clean into the new one. The backend
# container is stopped during the restore so nothing writes meanwhile, and
# started again afterwards even if the restore fails. --single-transaction
# makes a failed restore leave the new database as it was.
pg_ctr="brainkb-postgres-sandbox"
backend_ctr="brainkb-unified-sandbox"
psql_in="sudo docker exec -i $pg_ctr sh -c"
pg_counts="$psql_in 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tA -F \" \" -c \"select (select count(*) from spaces), (select count(*) from space_graphs)\"'"

do_postgres() {
  local bucket name old new answer
  bucket="$(tofu_out data_bucket_name)"
  name="old-sandbox-postgres-$(date -u +%Y%m%d-%H%M%S).dump"

  echo "1/5 Counting spaces on both sandboxes..."
  old="$(prod "$pg_counts")"
  [[ "$old" =~ ^[0-9]+\ [0-9]+$ ]] || die "couldn't count spaces on the old sandbox (got: $old)"
  new="$(sandbox "$pg_counts")"
  echo "    old sandbox: $(set -- $old; echo "$1 spaces, $2 graphs in spaces")"
  echo "    new sandbox: $(set -- $new; echo "$1 spaces, $2 graphs in spaces")"

  echo
  echo "This replaces the new sandbox's database (users, spaces, permissions, jobs)"
  echo "with a copy of the old sandbox's. The old sandbox is only read."
  read -r -p "Type yes to continue: " answer </dev/tty
  [ "$answer" = yes ] || die "stopped; nothing was changed"

  echo "2/5 Dumping the old sandbox's database to s3://$bucket/$prefix/$name..."
  prod "$psql_in 'pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Fc'" \
    | aws s3 cp - "s3://$bucket/$prefix/$name" --region "$region"
  aws s3 ls "s3://$bucket/$prefix/$name" --region "$region" --human-readable

  echo "3/5 Waiting for the file to appear on FSx..."
  local file="/fsx/$prefix/$name"
  sandbox "for i in \$(seq 1 30); do [ -s $file ] && exit 0; sleep 10; done; echo 'not on /fsx after 5 minutes' >&2; exit 1"

  echo "4/5 Restoring it with the backend stopped..."
  sandbox "sudo docker stop $backend_ctr >/dev/null
    $psql_in 'pg_restore -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" --clean --if-exists --no-owner --no-privileges --single-transaction' < $file
    status=\$?
    sudo docker start $backend_ctr >/dev/null
    exit \$status"

  echo "5/5 Comparing counts..."
  new="$(sandbox "$pg_counts")"
  echo "    old sandbox: $old   new sandbox: $new   (spaces, graphs in spaces)"
  [ "$new" = "$old" ] || die "counts differ"
  echo "Done: the counts match. The backend takes a minute or two to start."
}

case "${1:-}" in
  export) do_export ;;
  import) shift; do_import "$@" ;;
  postgres) do_postgres ;;
  *) die "usage: $0 export | $0 import <name> | $0 postgres" ;;
esac
