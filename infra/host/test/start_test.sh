#!/usr/bin/env bash
# Test for rentsync-start (feature 002 research R6; runbook §Secret rotation). A stub `docker`
# and render script on PATH stand in for the host, so no cloud or Docker is needed.
# Proves:
#   1. a telemetry start renders secrets, starts only openobserve-db, sets the openobserve
#      user's password to the SSM value through psql's stdin (never in argv), then starts the
#      rest, in that order;
#   2. if the password can't be set, the start fails and the stack is not brought up;
#   3. a telemetry host with no stack file yet starts nothing;
#   4. an environment host hands over to rentsync-deploy --reload;
#   5. an unknown role exits 1.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bin/rentsync-start"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

PW="Rotated0penObserveDbPassword4242"

mkdir -p "$work/bin" "$work/etc" "$work/run" "$work/opt"
touch "$work/opt/compose.yaml"

cat > "$work/bin/rentsync-render-env" <<STUB
#!/usr/bin/env bash
echo render >> "$work/calls.log"
printf "DB_NAME='openobserve_shared_us'\nOPENOBSERVE_DB_PASSWORD='%s'\n" "$PW" > "$work/run/env"
STUB

cat > "$work/bin/rentsync-deploy" <<STUB
#!/usr/bin/env bash
echo "deploy \$*" >> "$work/calls.log"
STUB

# docker stub: logs argv; for `exec`, also saves stdin, and fails if FAIL_PSQL is set.
cat > "$work/bin/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$work/calls.log"
case " \$* " in
  *" exec "*)
    cat > "$work/psql.stdin"
    [ -z "\${FAIL_PSQL:-}" ] || exit 2
    ;;
esac
STUB
chmod +x "$work/bin/"*

start() {
  rm -f "$work/calls.log" "$work/psql.stdin"
  PATH="$work/bin:$PATH" RENTSYNC_ETC="$work/etc" RENTSYNC_RUN="$work/run" RENTSYNC_BIN="$work/bin" \
    RENTSYNC_OPT="$work/opt" bash "$script"
}
role() {
  printf 'HOST_ROLE="%s"\nDEPLOYMENT_ID="shared-us"\nDB_NAME="openobserve_shared_us"\n' "$1" > "$work/etc/host.env"
}

# 1. Telemetry start: render, database, password, rest.
role telemetry
out="$(start)" || fail "telemetry start exited non-zero: $out"
grep -q "password matches SSM" <<< "$out" || fail "no confirmation line: $out"
steps="$(sed -E 's/^docker compose .* --env-file [^ ]+ /compose /' "$work/calls.log")"
expected="render
compose up -d --wait openobserve-db
compose exec -T openobserve-db psql -U openobserve -d openobserve_shared_us -q -v ON_ERROR_STOP=1
compose up -d --remove-orphans"
[ "$steps" = "$expected" ] || fail "wrong steps:
$steps"
[ "$(cat "$work/psql.stdin")" = "ALTER USER openobserve PASSWORD '$PW';" ] \
  || fail "psql got: $(cat "$work/psql.stdin")"
! grep -q "$PW" "$work/calls.log" || fail "the password appeared in a docker command line"

# 2. Password can't be set: fail, and don't start OpenObserve with a password Postgres refuses.
if FAIL_PSQL=1 start > /dev/null 2>&1; then fail "a failed ALTER USER did not fail the start"; fi
! grep -q -- "--remove-orphans" "$work/calls.log" || fail "the stack was started after a failed ALTER USER"

# 3. No stack file yet.
rm "$work/opt/compose.yaml"
out="$(start)"
grep -q "nothing to start" <<< "$out" || fail "missing stack file: $out"
[ ! -s "$work/calls.log" ] || fail "commands ran with no stack file: $(cat "$work/calls.log")"
touch "$work/opt/compose.yaml"

# 4. Environment host.
role environment
start > /dev/null
[ "$(cat "$work/calls.log")" = "deploy --reload" ] || fail "environment start: $(cat "$work/calls.log")"

# 5. Unknown role.
role bogus
if start > /dev/null 2>&1; then fail "an unknown role exited 0"; fi

echo "start_test: ok"
