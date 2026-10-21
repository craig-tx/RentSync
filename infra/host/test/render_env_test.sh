#!/usr/bin/env bash
# Test for rentsync-render-env (feature 002 research R11). A stub `aws` on PATH serves SSM
# parameters, so no cloud access is needed. Proves:
#   1. a complete parameter set renders a 0600 env file with every required key;
#   2. a missing required parameter fails the script and leaves no env file behind, so a host
#      never starts with an empty ADMIN_TOKEN (the admin API would fail open).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/rentsync-render-env"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin" "$work/etc" "$work/run"
cat > "$work/etc/host.env" <<'ENV'
HOST_ROLE="environment"
DEPLOYMENT_ID="pr-42"
DEPLOYMENT_ENVIRONMENT="staging"
DB_NAME="mock_pms_pr_42"
AWS_REGION="us-east-1"
SSM_READ_PATHS="/rentsync/pr-42 /rentsync/shared-us/openobserve/ingest"
ENV

# Stub: prints "<name>\t<value>" lines for the requested --path, skipping $OMIT.
cat > "$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
path=""
while [ $# -gt 0 ]; do [ "$1" = "--path" ] && path="$2"; shift; done
case "$path" in
  /rentsync/pr-42)
    for kv in admin_token=tok-123 postgres_password=pw-456 image_tag=abc previous_image_tag=none; do
      [ "${kv%%=*}" = "${OMIT:-}" ] && continue
      printf '%s/%s\t%s\n' "$path" "${kv%%=*}" "${kv#*=}"
    done ;;
  /rentsync/shared-us/openobserve/ingest)
    printf '%s/user\tops@example.test\n%s/password\tingest-789\n' "$path" "$path" ;;
esac
STUB
chmod +x "$work/bin/aws"

render() { PATH="$work/bin:$PATH" RENTSYNC_ETC="$work/etc" RENTSYNC_RUN="$work/run" bash "$script"; }

# 1. Complete set.
render > /dev/null || fail "render failed with every parameter present"
env_file="$work/run/env"
[ "$(stat -c %a "$env_file")" = "600" ] || fail "env file is not mode 600"
for line in ADMIN_TOKEN=tok-123 POSTGRES_PASSWORD=pw-456 IMAGE_TAG=abc OPENOBSERVE_USER=ops@example.test \
            OPENOBSERVE_PASSWORD=ingest-789 COMPOSE_PROJECT_NAME=rentsync-pr-42 DEPLOYMENT_ID=pr-42 \
            "DATABASE_URL=postgres://postgres:pw-456@postgres:5432/mock_pms_pr_42"; do
  grep -qxF "$line" "$env_file" || fail "env file lacks $line"
done
if grep -q "SSM_READ_PATHS\|VOLUME_ID" "$env_file"; then fail "script-only keys leaked into the env file"; fi
if render 2>&1 | grep -q "tok-123"; then fail "a secret value was printed"; fi

# 2. Missing required parameter.
rm -f "$env_file"
if OMIT=admin_token render > /dev/null 2>&1; then fail "render succeeded without admin_token"; fi
[ ! -e "$env_file" ] || fail "an env file was written despite a missing parameter"

echo "ok: render_env_test"
