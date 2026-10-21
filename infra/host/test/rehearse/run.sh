#!/usr/bin/env bash
# Host rehearsal (feature 002): runs the REAL host scripts and Compose files against real
# containers, inside a privileged docker:dind container that stands in for an EC2 host.
# Only AWS is faked: a stub `aws` serves SSM parameters from files, a local registry stands in
# for ECR, and a loop device stands in for the EBS data volume. Driven by rehearse.sh; not run
# in CI (it takes several minutes and needs privileged Docker).
#
# Usage (inside the dind container): run.sh <good_sha_a> <good_sha_b>
# Images localhost:5000/shared-us/mock_pms:<sha> must report SERVICE_VERSION=<sha>.
set -euo pipefail

A="$1"
B="$2"
BAD="$(printf 'c%.0s' {1..40})" # a re-tag of A: it reports version A, so its health check fails
repo=/repo
store=/var/lib/fake-ssm
ip="$(hostname -i | awk '{print $1}')" # the "private IP" of this host
step() { printf '\n=== %s\n' "$*"; }
fail() { echo "REHEARSAL FAIL: $*" >&2; exit 1; }

step "install host tools (the AMI has these)"
apk add --no-cache -q bash jq util-linux xfsprogs blkid curl coreutils > /dev/null

step "lay files out as cloud-init would"
mkdir -p /opt/rentsync /etc/rentsync /usr/local/bin "$store"
cp "$repo/infra/host/compose.env.yaml" /opt/rentsync/compose.yaml
cp "$repo/infra/host/Caddyfile.env" /opt/rentsync/Caddyfile
cp "$repo/infra/otel/collector.yaml" /opt/rentsync/collector.yaml
for s in rentsync-boot rentsync-render-env rentsync-start rentsync-deploy; do
  install -m 0755 "$repo/infra/host/bin/$s" "/usr/local/bin/$s"
done
cat > /etc/rentsync/host.env <<ENV
HOST_ROLE="environment"
DEPLOYMENT_ID="pr-42"
DEPLOYMENT_ENVIRONMENT="staging"
SITE_HOSTNAME="localhost"
DB_NAME="mock_pms_pr_42"
AWS_REGION="us-east-1"
SSM_READ_PATHS="/rentsync/pr-42 /rentsync/shared-us/openobserve/ingest"
ECR_REPOSITORY_URL="localhost:5000/shared-us/mock_pms"
OPENOBSERVE_OTLP_ENDPOINT="http://$ip:5080/api/default"
ACME_EMAIL="ops@example.test"
ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory"
VOLUME_ID="vol-rehearsal"
ENV

step "fake SSM parameters (what Terraform writes)"
put() { mkdir -p "$(dirname "$store$1")"; printf '%s' "$2" > "$store$1"; }
put /rentsync/pr-42/admin_token "rehearsal-admin-token-0123456789abcdef"
put /rentsync/pr-42/postgres_password "rehearsalPgPassw0rd"
put /rentsync/pr-42/image_tag none
put /rentsync/pr-42/previous_image_tag none
put /rentsync/shared-us/openobserve/ingest/user "ops@example.test"
put /rentsync/shared-us/openobserve/ingest/password "Rehearsal-0nly-Passw0rd!"
cat > /usr/local/bin/aws <<STUB
#!/usr/bin/env bash
# Stub of the AWS CLI calls the host scripts make.
case "\$1 \$2" in
  "ssm get-parameters-by-path")
    path=""; while [ \$# -gt 0 ]; do [ "\$1" = --path ] && path="\$2"; shift; done
    [ -d "$store\$path" ] || exit 0
    find "$store\$path" -type f | sort | while read -r f; do printf '%s\t%s\n' "\${f#$store}" "\$(cat "\$f")"; done ;;
  "ssm put-parameter")
    while [ \$# -gt 0 ]; do case "\$1" in --name) n="\$2" ;; --value) v="\$2" ;; esac; shift; done
    mkdir -p "\$(dirname "$store\$n")"; printf '%s' "\$v" > "$store\$n" ;;
  "ecr get-login-password") echo rehearsal ;;
  *) echo "aws stub: unexpected call: \$*" >&2; exit 1 ;;
esac
STUB
chmod 0755 /usr/local/bin/aws

step "data volume on a loop device; rentsync-boot formats it once"
truncate -s 2G /var/lib/data.img
loop="$(losetup --find --show /var/lib/data.img)"
RENTSYNC_DATA_DEVICE="$loop" rentsync-boot

step "registry standing in for ECR; push A, B and the bad tag"
docker run -d --name registry -p 5000:5000 registry:2.8.3 > /dev/null
for _ in $(seq 1 30); do curl -fs localhost:5000/v2/ > /dev/null && break; sleep 1; done
for t in "$A" "$B"; do
  docker tag "rehearsal:$t" "localhost:5000/shared-us/mock_pms:$t"
  docker push -q "localhost:5000/shared-us/mock_pms:$t" > /dev/null
done
docker tag "rehearsal:$A" "localhost:5000/shared-us/mock_pms:$BAD"
docker push -q "localhost:5000/shared-us/mock_pms:$BAD" > /dev/null

step "shared telemetry: OpenObserve and its Postgres on this host's private IP"
cat > /tmp/telemetry.env <<ENV
SITE_HOSTNAME=telemetry.localhost
ACME_EMAIL=ops@example.test
ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
ZO_ROOT_USER_EMAIL=ops@example.test
ZO_ROOT_USER_PASSWORD=Rehearsal-0nly-Passw0rd!
OPENOBSERVE_DB_PASSWORD=rehearsalOoDbPassw0rd
DB_NAME=openobserve_shared_us
PRIVATE_IP=$ip
ENV
docker compose -p rentsync-shared-us -f "$repo/infra/host/compose.telemetry.yaml" --env-file /tmp/telemetry.env \
  up -d --quiet-pull openobserve openobserve-db
for _ in $(seq 1 60); do curl -fs "http://$ip:5080/healthz" > /dev/null && break; sleep 2; done
curl -fs "http://$ip:5080/healthz" > /dev/null || fail "OpenObserve did not come up on $ip:5080"

compose() { docker compose -p rentsync-pr-42 --project-directory /opt/rentsync -f /opt/rentsync/compose.yaml --env-file /run/rentsync/env "$@"; }
tags() { echo "$(cat "$store/rentsync/pr-42/image_tag") $(cat "$store/rentsync/pr-42/previous_image_tag")"; }
admin() { curl -sk -H "Authorization: Bearer rehearsal-admin-token-0123456789abcdef" -H "Content-Type: application/json" "$@"; }

step "first boot with nothing deployed: rentsync-start -> --reload starts only Caddy"
out="$(rentsync-start)"
echo "$out"
echo "$out" | grep -qx "no image deployed yet" || fail "first boot did not report 'no image deployed yet'"
[ "$(stat -c %a /run/rentsync/env)" = 600 ] || fail "/run/rentsync/env is not 0600"

step "deploy A (first deploy: creates, migrates and seeds mock_pms_pr_42)"
rentsync-deploy "$A" | tee /tmp/deploy-a.log
grep -qx "deployed $A" /tmp/deploy-a.log || fail "deploy A did not report deployed"
[ "$(tags)" = "$A none" ] || fail "after A, SSM tags are $(tags)"

step "through Caddy: /healthz, /metrics hidden, HTTP redirects"
health="$(curl -sk https://localhost/healthz)"
echo "$health"
[ "$(jq -r '.status + " " + .version + " " + .deployment_id' <<< "$health")" = "ok $A pr-42" ] || fail "healthz via Caddy: $health"
[ "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/metrics)" = 404 ] || fail "/metrics is public"
code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost/healthz)"
[[ "$code" =~ ^30[178]$ ]] || fail "HTTP did not redirect (got $code)"
[ "$(admin -o /dev/null -w '%{http_code}' https://localhost/admin/clients -H 'Authorization: Bearer wrong')" = 401 ] || fail "admin API accepted a wrong token"
# Capture before matching: with pipefail, grep -q closing the pipe early fails the producer.
dbs="$(compose exec -T postgres psql -U postgres -Atc "select datname from pg_database")"
grep -qx mock_pms_pr_42 <<< "$dbs" || fail "database mock_pms_pr_42 missing (have: $dbs)"

step "data that must survive: register a client"
client="$(admin -X POST https://localhost/admin/clients -d '{"name":"rehearsal","redirect_uris":["http://localhost:9999/cb"],"subscriber_url":"http://receiver:9999/webhooks"}')"
client_id="$(jq -r .client_id <<< "$client")"
[[ "$client_id" == client_* ]] || fail "client registration failed: $client"
admin -X POST https://localhost/admin/scenarios/tenant_move_out -d '{}' > /dev/null

step "deploy B: migrate only (no reseed), the client survives"
rentsync-deploy "$B" | tee /tmp/deploy-b.log
grep -qx "deployed $B" /tmp/deploy-b.log || fail "deploy B did not report deployed"
[ "$(tags)" = "$B $A" ] || fail "after B, SSM tags are $(tags)"
clients="$(admin "https://localhost/admin/clients")"
grep -q "$client_id" <<< "$clients" || fail "client $client_id lost on deploy B"

step "same tag again is a no-op"
out="$(rentsync-deploy "$B")"
grep -qx "already running $B" <<< "$out" || fail "redeploying B was not a no-op: $out"

step "a bad image is rolled back automatically (exit 1)"
set +e
RENTSYNC_HEALTH_TRIES=10 rentsync-deploy "$BAD" | tee /tmp/deploy-bad.log
code="${PIPESTATUS[0]}"
set -e
[ "$code" = 1 ] || fail "bad deploy exited $code, expected 1"
grep -qx "rolled back to $B" /tmp/deploy-bad.log || fail "bad deploy did not roll back to B"
[ "$(tags)" = "$B $A" ] || fail "a failed deploy changed SSM: $(tags)"
[ "$(curl -sk https://localhost/healthz | jq -r .version)" = "$B" ] || fail "B is not serving after the rollback"

step "telemetry reaches OpenObserve with deployment.id=pr-42"
admin -X POST https://localhost/admin/scenarios/tenant_move_out -d '{}' > /dev/null
compose exec -T -e OPENOBSERVE_URL="http://$ip:5080" -e OPENOBSERVE_USER=ops@example.test \
  -e "OPENOBSERVE_PASSWORD=Rehearsal-0nly-Passw0rd!" -e TELEMETRY_SMOKE_TIMEOUT_S=120 \
  mock_pms bundle exec bin/telemetry_smoke || fail "telemetry did not arrive with deployment attributes"

step "--rollback swaps to A"
out="$(rentsync-deploy --rollback)"
grep -qx "deployed $A" <<< "$out" || fail "--rollback did not deploy A: $out"
[ "$(tags)" = "$A $B" ] || fail "after --rollback, SSM tags are $(tags)"

step "host replacement: containers gone, volume detached and re-attached, boot again"
compose down > /dev/null 2>&1
docker compose -p rentsync-shared-us -f "$repo/infra/host/compose.telemetry.yaml" --env-file /tmp/telemetry.env stop > /dev/null 2>&1
umount /srv/data
rm -rf /run/rentsync
RENTSYNC_DATA_DEVICE="$loop" rentsync-boot | tee /tmp/boot-2.log
grep -q "existing filesystem" /tmp/boot-2.log || fail "the second boot did not find the existing filesystem"
rentsync-start | tee /tmp/start-2.log
grep -qx "deployed $A" /tmp/start-2.log || fail "the replaced host did not come back on A"
clients="$(admin "https://localhost/admin/clients")"
grep -q "$client_id" <<< "$clients" || fail "client $client_id lost across host replacement"
ls /srv/data/caddy/caddy > /dev/null 2>&1 || fail "Caddy's data did not persist on the volume"

step "no secret in the rendered compose project's logs"
logs="$(compose logs 2>&1)"
if grep -E "rehearsal-admin-token|rehearsalPgPassw0rd|Rehearsal-0nly-Passw0rd" <<< "$logs"; then
  fail "a secret value appeared in container logs"
fi

printf '\nREHEARSAL OK\n'
