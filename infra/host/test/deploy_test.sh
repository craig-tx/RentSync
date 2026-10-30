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
#   7. a healthy deploy that SSM cannot record exits 3 and keeps serving the new image;
#   8. a digest-pinned <sha>@sha256:<digest> deploys and is recorded whole; a bad digest is 64;
#   9. feature 003: <sha>@sha256:<mock>+sha256:<api> deploys both images at one SHA, runs both
#      setups (the mock first, since RentSync registers with it), records the ref whole, and
#      succeeds only when both /healthz report the SHA;
#  10. an unhealthy API rolls both images back to the previous ref, exit 1, SSM unchanged;
#  11. a ref without an API digest (every release before feature 003) runs the mock alone and
#      stops the API, so a rollback or reload to such a ref still works;
#  12. an API digest on a host with no API repository is refused with exit 64.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/rentsync-deploy"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

A="$(printf 'a%.0s' {1..40})"
B="$(printf 'b%.0s' {1..40})"
BAD="$(printf 'c%.0s' {1..40})" # an image whose /healthz never reports ok
BAD_API="$(printf 'e%.0s' {1..40})" # a release whose mock is healthy and whose API never is
M="sha256:$(printf '1%.0s' {1..64})" # a mock digest
P="sha256:$(printf '2%.0s' {1..64})" # an API digest

mkdir -p "$work/bin" "$work/etc" "$work/run" "$work/ssm"
cat > "$work/etc/host.env" <<'ENV'
DEPLOYMENT_ID="pr-42"
AWS_REGION="us-east-1"
SSM_READ_PATHS="/rentsync/pr-42 /rentsync/shared-us/openobserve/ingest"
ECR_REPOSITORY_URL="123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms"
API_ECR_REPOSITORY_URL="123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/api"
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

# docker stub: `up` records which image runs (the API separately, in api_running); `exec ...
# curl` reports it healthy unless BAD (the mock) or BAD_API (the API); `pull` logs the images.
cat > "$work/bin/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$work/docker.log"
case " \$* " in
  *" pull "*) echo "pull mock=\$MOCK_PMS_IMAGE api=\${API_IMAGE:-}" >> "$work/pull.log" ;;
  *" rm -sf api api_worker "*) rm -f "$work/api_running" ;;
  *" --profile api up "*) ref="\${API_IMAGE#*/api:}"; printf '%s' "\${ref%%@*}" > "$work/api_running" ;;
  *" exec -T api "*)
    tag="\$(cat "$work/api_running" 2>/dev/null || true)"
    if [ -n "\$tag" ] && [ "\$tag" != "$BAD_API" ]; then
      printf '{"status":"ok","version":"%s","deployment_id":"pr-42"}' "\$tag"
    else
      printf '{"status":"degraded","version":"%s","deployment_id":"pr-42"}' "\$tag"
    fi ;;
  *" up "*" caddy"*) echo caddy > "$work/running" ;;
  *" up "*) ref="\${MOCK_PMS_IMAGE#*/mock_pms:}"; printf '%s' "\${ref%%@*}" > "$work/running" ;;
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

state() { printf 'none' > "$work/ssm/image_tag"; printf 'none' > "$work/ssm/previous_image_tag"; rm -f "$work/running" "$work/api_running"; }
api_running() { cat "$work/api_running" 2> /dev/null || echo stopped; }
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
out="$(deploy "$A")" || fail "deploy A failed: $out"
grep -qx "deployed $A" <<< "$out" || fail "deploy A did not report deployed"
[ "$(tags)" = "$A none" ] || fail "after deploy A, tags are $(tags)"
grep -q "bin/setup --deploy" "$work/docker.log" || fail "deploy did not run bin/setup --deploy"

# 2. Same tag again: no-op.
: > "$work/docker.log"
out="$(deploy "$A")" || fail "redeploying A failed: $out"
grep -qx "already running $A" <<< "$out" || fail "redeploying A was not a no-op"
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
grep -qx "rolled back to $B" <<< "$out" || fail "a bad deploy printed: $out"
[ "$(tags)" = "$B $A" ] || fail "a failed deploy changed SSM: $(tags)"
[ "$(cat "$work/running")" = "$B" ] || fail "B is not running after the rollback"

# 4. --rollback swaps.
out="$(deploy --rollback)" || fail "--rollback failed: $out"
grep -qx "deployed $A" <<< "$out" || fail "--rollback did not deploy A"
[ "$(tags)" = "$A $B" ] || fail "after --rollback, tags are $(tags)"

# 8. A digest-pinned ref deploys (the version check uses its SHA part) and is recorded whole,
#    so reboots and rollbacks keep pulling exactly that image.
D="$A@sha256:$(printf 'd%.0s' {1..64})"
out="$(deploy "$D")" || fail "a digest-pinned deploy failed: $out"
grep -qx "deployed $D" <<< "$out" || fail "a digest-pinned deploy printed: $out"
[ "$(cat "$work/running")" = "$A" ] || fail "the digest-pinned image is not running"
[ "$(cat "$work/ssm/image_tag")" = "$D" ] || fail "SSM did not record the digest-pinned ref: $(cat "$work/ssm/image_tag")"
set +e
deploy "$A@sha256:short" 2> /dev/null
code=$?
set -e
[ "$code" -eq 64 ] || fail "a malformed digest exited $code, expected 64"

# 7. The new image is healthy but SSM can't record it: exit 3, still serving the new image.
set +e
out="$(FAIL_PUT=1 deploy "$B")"
code=$?
set -e
[ "$code" -eq 3 ] || fail "an unrecordable deploy exited $code, expected 3"
grep -q "SSM could not record it" <<< "$out" || fail "an unrecordable deploy printed: $out"
[ "$(cat "$work/running")" = "$B" ] || fail "B is not serving after an unrecordable deploy"

# 6. Malformed tag.
set +e
deploy "not-a-sha" 2> /dev/null
code=$?
set -e
[ "$code" -eq 64 ] || fail "a malformed tag exited $code, expected 64"

# 9. Both images at one SHA, from the start (B legacy is running now, after case 7).
state
deploy "$A@$M" > /dev/null || fail "deploy of a legacy ref failed"
: > "$work/docker.log"
: > "$work/pull.log"
R1="$B@$M+$P"
out="$(deploy "$R1")" || fail "a two-image deploy failed: $out"
grep -qx "deployed $R1" <<< "$out" || fail "a two-image deploy printed: $out"
grep -qx "pull mock=123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/mock_pms:$B@$M api=123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-us/api:$B@$P" "$work/pull.log" \
  || fail "the images pulled were: $(cat "$work/pull.log")"
mock_setup="$(grep -n "run --rm mock_pms bundle exec bin/setup --deploy" "$work/docker.log" | head -1 | cut -d: -f1)"
api_setup="$(grep -n "run --rm api bundle exec bin/setup --deploy" "$work/docker.log" | head -1 | cut -d: -f1)"
if ! { [ -n "$mock_setup" ] && [ -n "$api_setup" ]; }; then fail "a two-image deploy did not run both setups"; fi
[ "$mock_setup" -lt "$api_setup" ] || fail "the API's setup ran before the mock's"
if ! { [ "$(cat "$work/running")" = "$B" ] && [ "$(api_running)" = "$B" ]; }; then fail "running: mock $(cat "$work/running"), api $(api_running)"; fi
[ "$(tags)" = "$R1 $A@$M" ] || fail "after a two-image deploy, tags are $(tags)"
: > "$work/docker.log"
out="$(deploy "$R1")" || fail "redeploying a two-image ref failed: $out"
grep -qx "already running $R1" <<< "$out" || fail "redeploying a two-image ref was not a no-op: $out"

# 10. A healthy mock but an unhealthy API rolls both back.
set +e
out="$(deploy "$BAD_API@$M+$P")"
code=$?
set -e
[ "$code" -eq 1 ] || fail "an unhealthy API exited $code, expected 1: $out"
grep -qx "rolled back to $R1" <<< "$out" || fail "an unhealthy API printed: $out"
[ "$(tags)" = "$R1 $A@$M" ] || fail "a failed two-image deploy changed SSM: $(tags)"
if ! { [ "$(cat "$work/running")" = "$B" ] && [ "$(api_running)" = "$B" ]; }; then fail "after the rollback: mock $(cat "$work/running"), api $(api_running)"; fi

# 11. Rolling back to a release from before the API runs the mock alone and stops the API.
: > "$work/docker.log"
out="$(deploy --rollback)" || fail "--rollback to a legacy ref failed: $out"
grep -qx "deployed $A@$M" <<< "$out" || fail "--rollback to a legacy ref printed: $out"
[ "$(cat "$work/running")" = "$A" ] || fail "the mock is not on A after the rollback"
[ "$(api_running)" = stopped ] || fail "the API still runs $(api_running) after rolling back to a legacy ref"
if grep -q "run --rm api" "$work/docker.log"; then fail "the API's setup ran for a legacy ref"; fi
#     The first two-image release fails: the joint rollback lands on the legacy ref.
set +e
out="$(deploy "$BAD_API@$M+$P")"
code=$?
set -e
[ "$code" -eq 1 ] || fail "a failed first two-image release exited $code: $out"
if ! { [ "$(cat "$work/running")" = "$A" ] && [ "$(api_running)" = stopped ]; }; then fail "after a failed first release: mock $(cat "$work/running"), api $(api_running)"; fi

# 12. A host without an API repository refuses an API digest.
sed -i '/^API_ECR_REPOSITORY_URL=/d' "$work/etc/host.env"
set +e
out="$(deploy "$R1" 2>&1)"
code=$?
set -e
[ "$code" -eq 64 ] || fail "an API digest without an API repository exited $code, expected 64: $out"

echo "ok: deploy_test"
