#!/usr/bin/env bash
# Test for infra/release/run-deploy.sh. A stub `aws` plays back one outcome per send-command,
# so no cloud is needed. Proves:
#   1. a deploy that succeeds first time is sent once, waits for cloud-init, and passes the
#      pinned argument and a short comment;
#   2. a host that went away mid-deploy (killed, exit -1) is retried, and the retry's success
#      passes;
#   3. no tagged host (between the old host going and the new one registering) is retried;
#   4. a failure from rentsync-deploy itself (1: rolled back) is final, not retried;
#   5. retries stop at the deadline with a reason.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../run-deploy.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

SHA="$(printf 'a%.0s' {1..40})"
ARG="$SHA@sha256:$(printf 'd%.0s' {1..64})"

mkdir -p "$work/bin"
# Each line of $work/outcomes is "<instance> <status> <exit code>" for one send-command;
# "None" as the instance means no host matched. The last line repeats once the list runs out.
cat > "$work/bin/aws" <<STUB
#!/usr/bin/env bash
n="\$(cat "$work/sent" 2>/dev/null || echo 0)"
line="\$(sed -n "\${n}p" "$work/outcomes")"
[ -n "\$line" ] || line="\$(tail -n 1 "$work/outcomes")"
read -r instance status code <<< "\$line"
case "\$2" in
  send-command)
    echo "\$*" >> "$work/send.log"
    echo \$((n + 1)) > "$work/sent"
    echo "cmd-\$((n + 1))"
    ;;
  list-command-invocations)
    case "\$*" in
      *Status*) [ "\$instance" = None ] && echo None || echo "\$status" ;;
      *InstanceId*) echo "\$instance" ;;
    esac
    ;;
  get-command-invocation)
    case "\$*" in
      *ResponseCode*) echo "\$code" ;;
      *) echo "host output" ;;
    esac
    ;;
esac
STUB
chmod +x "$work/bin/aws"

run() {
  rm -f "$work/sent" "$work/send.log"
  printf '%s\n' "$@" > "$work/outcomes"
  PATH="$work/bin:$PATH" RUN_DEPLOY_DEADLINE_S="${DEADLINE:-60}" RUN_DEPLOY_RETRY_DELAY_S=0 \
    RUN_DEPLOY_POLL_S=0 bash "$script" dev-staging "$ARG"
}
sends() { wc -l < "$work/send.log" | tr -d ' '; }

# 1. First-time success.
out="$(run "i-new Success 0")" || fail "a successful deploy failed: $out"
[ "$(sends)" = 1 ] || fail "sent $(sends) times"
grep -q 'cloud-init status --wait' "$work/send.log" || fail "the host does not wait for cloud-init"
grep -q "rentsync-deploy $ARG" "$work/send.log" || fail "the pinned argument was not passed"
grep -q -- "--comment rentsync-deploy dev-staging $SHA " "$work/send.log" || fail "comment: $(cat "$work/send.log")"
grep -q "Key=tag:DeploymentId,Values=dev-staging" "$work/send.log" || fail "wrong target"

# 2. Old host killed mid-deploy, then the new host succeeds.
out="$(run "i-old Failed -1" "i-new Success 0")" || fail "the retry's success did not pass: $out"
[ "$(sends)" = 2 ] || fail "sent $(sends) times, expected 2"
grep -q "may be being replaced" <<< "$out" || fail "no reason given: $out"

# 3. No host tagged yet, then the new host succeeds.
out="$(run "None x x" "None x x" "i-new Success 0")" || fail "did not wait for a tagged host: $out"
[ "$(sends)" = 3 ] || fail "sent $(sends) times, expected 3"

# 4. rentsync-deploy rolled back: final.
if out="$(run "i-new Failed 1" "i-new Success 0")"; then fail "a rollback (exit 1) passed"; fi
[ "$(sends)" = 1 ] || fail "a rollback was retried ($(sends) sends)"

# 5. Deadline.
if out="$(DEADLINE=0 run "None x x")"; then fail "passed with no host"; fi
grep -q "giving up: no instance tagged" <<< "$out" || fail "no reason at the deadline: $out"

echo "run_deploy_test: ok"
