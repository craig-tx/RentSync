#!/usr/bin/env bash
# Test for rentsync-deploy (feature 002 research R9, contracts/host-interface.md). Stub `docker`,
# `aws` and render script on PATH stand in for the host, so no cloud or Docker is needed.
# Proves:
#   1. a healthy deploy records image_tag and previous_image_tag and exits 0;
#   2. deploying the running, healthy tag is a no-op;
#   3. an unhealthy tag is rolled back to the previous one, exit 1, and SSM is unchanged;
#   4. --rollback swaps image_tag and previous_image_tag;
#   5. --reload with nothing deployed starts only Caddy;
#   6. a malformed tag is rejected with exit 64;
#   7. a healthy deploy that SSM cannot record exits 3 and keeps serving the new image.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/rentsync-deploy"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

A="$(printf 'a%.0s' {1..40})"
B="$(printf 'b%.0s' {1..40})"
BAD="$(printf 'c%.0s' {1..40})" # an image whose /healthz never reports ok

mkdir -p "$work/bin" "$work/etc" "$work/run" "$work/ssm"
cat > "$work/etc/host.env" <<'ENV'
DEPLOYMENT_ID="pr-42"
AWS_REGION="us-east-1"
SSM_READ_PATHS="/rentsync/pr-42 /rentsync/shared-us/openobserve/ingest"
ECR_REPOSITORY_URL="123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms"
ENV

# Render stub: writes the env file from the fake SSM state.
cat > "$work/bin/render" <<STUB
#!/usr/bin/env bash
printf "IMAGE_TAG='%s'\nPREVIOUS_IMAGE_TAG='%s'\n" "\$(cat $work/ssm/image_tag)" "\$(cat $work/ssm/previous_image_tag)" > $work/run/env
STUB

# aws stub: put-parameter writes the fake SSM state; get-login-password prints a token.
cat > "$work/bin/aws" <<STUB
#!/usr/bin/env bash
if [ "\$2" = "put-parameter" ]; then
  [ -n "\${FAIL_PUT:-}" ] && exit 255
  while [ \$# -gt 0 ]; do
    case "\$1" in --name) name="\${2##*/}" ;; --value) value="\$2" ;; esac
    shift
  done
  printf '%s' "\$value" > "$work/ssm/\$name"
fi
STUB

# docker stub: `up` records which image runs; `exec ... curl` reports it healthy unless BAD.
cat > "$work/bin/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$work/docker.log"
case " \$* " in
  *" up "*" caddy"*) echo caddy > "$work/running" ;;
  *" up "*) printf '%s' "\${MOCK_PMS_IMAGE##*:}" > "$work/running" ;;
  *" exec -T "*)
    tag="\$(cat "$work/running" 2>/dev/null || true)"
    if [ -n "\$tag" ] && [ "\$tag" != "$BAD" ] && [ "\$tag" != caddy ]; then
      printf '{"status":"ok","version":"%s","deployment_id":"pr-42"}' "\$tag"
    else
      printf '{"status":"degraded","version":"%s","deployment_id":"pr-42"}' "\$tag"
    fi ;;
esac
exit 0
STUB
chmod +x "$work/bin/"*

state() { printf 'none' > "$work/ssm/image_tag"; printf 'none' > "$work/ssm/previous_image_tag"; rm -f "$work/running"; }
tags() { echo "$(cat "$work/ssm/image_tag") $(cat "$work/ssm/previous_image_tag")"; }
deploy() {
  PATH="$work/bin:$PATH" RENTSYNC_ETC="$work/etc" RENTSYNC_RUN="$work/run" RENTSYNC_RENDER="$work/bin/render" \
    RENTSYNC_HEALTH_TRIES=2 RENTSYNC_HEALTH_INTERVAL_S=0 RENTSYNC_PUT_BACKOFF_S=0 bash "$script" "$@"
}

state
# 5. Nothing deployed yet: --reload starts only Caddy.
out="$(deploy --reload)" || fail "--reload with nothing deployed failed"
[ "$out" = "no image deployed yet" ] || fail "--reload printed: $out"
[ "$(cat "$work/running")" = caddy ] || fail "--reload did not start caddy"

# 1. First deploy.
deploy "$A" | grep -qx "deployed $A" || fail "deploy A did not report deployed"
[ "$(tags)" = "$A none" ] || fail "after deploy A, tags are $(tags)"
grep -q "bin/setup --deploy" "$work/docker.log" || fail "deploy did not run bin/setup --deploy"

# 2. Same tag again: no-op.
: > "$work/docker.log"
deploy "$A" | grep -qx "already running $A" || fail "redeploying A was not a no-op"
if grep -q " up " "$work/docker.log"; then fail "the no-op restarted containers"; fi

# Second deploy.
deploy "$B" > /dev/null || fail "deploy B failed"
[ "$(tags)" = "$B $A" ] || fail "after deploy B, tags are $(tags)"

# 3. A bad image rolls back.
set +e
out="$(deploy "$BAD")"
code=$?
set -e
[ "$code" -eq 1 ] || fail "a bad deploy exited $code, expected 1"
echo "$out" | grep -qx "rolled back to $B" || fail "a bad deploy printed: $out"
[ "$(tags)" = "$B $A" ] || fail "a failed deploy changed SSM: $(tags)"
[ "$(cat "$work/running")" = "$B" ] || fail "B is not running after the rollback"

# 4. --rollback swaps.
deploy --rollback | grep -qx "deployed $A" || fail "--rollback did not deploy A"
[ "$(tags)" = "$A $B" ] || fail "after --rollback, tags are $(tags)"

# 7. The new image is healthy but SSM can't record it: exit 3, still serving the new image.
set +e
out="$(FAIL_PUT=1 deploy "$B")"
code=$?
set -e
[ "$code" -eq 3 ] || fail "an unrecordable deploy exited $code, expected 3"
echo "$out" | grep -q "SSM could not record it" || fail "an unrecordable deploy printed: $out"
[ "$(cat "$work/running")" = "$B" ] || fail "B is not serving after an unrecordable deploy"

# 6. Malformed tag.
set +e
deploy "not-a-sha" 2> /dev/null
code=$?
set -e
[ "$code" -eq 64 ] || fail "a malformed tag exited $code, expected 64"

echo "ok: deploy_test"
