#!/usr/bin/env bash
# Test for bootstrap-operator.sh (runbook §Operator CLI access). A stub `aws` on PATH simulates
# IAM, STS and Access Analyzer and logs every call, so no cloud access is needed. Proves:
#   1. the render fills every placeholder; the role trusts exactly the identity running the
#      script, an assumed role by its real ARN (path included), or the --principal given;
#   2. the root user, an identity in another AWS account, a mismatched AWS account and a missing
#      settings file all fail before any change;
#   3. plan mode makes no mutating call, and prints the ~/.aws/config profiles;
#   4. --apply creates the policy and the one-hour role, and attaches both policies; on a rerun
#      it re-creates nothing and refreshes the trust;
#   5. an Access Analyzer ERROR stops the run before any change;
#   6. the policy decrypts only admin tokens, and grants no reboot, stop or terminate;
#   7. --teardown (at a terminal, after the sum) deletes exactly the role and policy, and
#      refuses on a wrong answer, no terminal, or a policy shared with something else.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bootstrap-operator.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
# Stub state: $EXISTING lists "policy:<name>" and "role:<name>" entries; $FINDING names a
# rendered file on which validate-policy reports an ERROR; $CALLER is the ARN STS reports, and
# $STS_ACCOUNT the AWS account ID.
cat > "$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AWS_LOG"
has() { case " ${EXISTING:-} " in *" $1 "*) return 0 ;; esac; return 1; }
arg() { local want="$1"; shift; while [ $# -gt 1 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "sts get-caller-identity")
    printf '%s\t%s\n' "${STS_ACCOUNT:-123456789012}" "${CALLER:-arn:aws:iam::123456789012:user/ops}" ;;
  "accessanalyzer validate-policy")
    if [ -n "${FINDING:-}" ] && [[ "$(arg --policy-document "$@")" == *"/$FINDING" ]]; then
      printf 'ERROR\tMALFORMED_ARN\tThe ARN is malformed.\n'
    fi ;;
  "iam get-policy")
    has "policy:$(arg --policy-arn "$@" | sed 's|.*/||')" || { echo "An error occurred (NoSuchEntity)" >&2; exit 254; } ;;
  "iam get-role")
    r="$(arg --role-name "$@")"
    case "$r" in
      AWSReservedSSO_*) echo "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/$r" ;;
      *) has "role:$r" || { echo "An error occurred (NoSuchEntity)" >&2; exit 254; } ;;
    esac ;;
  "iam list-attached-role-policies")
    echo "arn:aws:iam::123456789012:policy/rentsync-operator	arn:aws:iam::aws:policy/ReadOnlyAccess" ;;
  "iam list-role-policies") echo ;;
  "iam list-entities-for-policy")
    printf 'rentsync-operator'; [ -n "${SHARED_POLICY:-}" ] && printf '\tsomeone'; echo ;;
  "iam list-policy-versions") echo v1 ;;
  *) ;;
esac
STUB
chmod +x "$work/bin/aws"

# Not the reference deployment's region.
cat > "$work/settings.env" <<EOF
RENTSYNC_AWS_ACCOUNT_ID='123456789012'
RENTSYNC_AWS_REGION='eu-west-2'
EOF

export AWS_LOG="$work/aws.log" RENTSYNC_SETTINGS="$work/settings.env"
run() { : > "$AWS_LOG"; PATH="$work/bin:$PATH" RENTSYNC_IAM_OUT="$work/out" bash "$script" "$@"; }
mutations() { grep -cE '^iam (create|update|attach|put|tag)-' "$AWS_LOG" || true; }
calls() { grep -c "^iam $1 " "$AWS_LOG" || true; }
trusted() { jq -r '.Statement[0].Principal.AWS' "$work/out/operator/trust.json"; }

# 1. Render and trust.
plan="$(run)" || fail "plan failed"
if grep -l '<[a-z-]*>' "$work/out/operator"/*.json; then fail "a placeholder survived the render"; fi
[ "$(trusted)" = "arn:aws:iam::123456789012:user/ops" ] || fail "trust is not the caller: $(trusted)"
grep -q 'arn:aws:ec2:eu-west-2:123456789012:instance/\*' "$work/out/operator/policy.json" || fail "region or AWS account not filled in"
if grep -q 'us-east-1' "$work/out/operator"/*.json; then fail "a reference-deployment region is hard-coded"; fi
jq -e . "$work/out/operator/policy.json" > /dev/null || fail "rendered policy is not JSON"

CALLER="arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_Admin_abc123/someone" run > /dev/null || fail "an assumed role failed"
[ "$(trusted)" = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Admin_abc123" ] \
  || fail "an assumed role was not trusted by its real ARN: $(trusted)"
run --principal arn:aws:iam::123456789012:user/other > /dev/null || fail "--principal failed"
[ "$(trusted)" = "arn:aws:iam::123456789012:user/other" ] || fail "--principal was not used"

# 2. Bad identities and settings fail before any change.
if CALLER="arn:aws:iam::123456789012:root" run --apply > "$work/err" 2>&1; then fail "trusted the root user"; fi
grep -q 'root user, which cannot assume a role' "$work/err" || fail "the root refusal was not explained"
if run --apply --principal arn:aws:iam::999999999999:user/x > /dev/null 2>&1; then fail "trusted another AWS account's user"; fi
if run --apply --principal arn:aws:iam::123456789012:role/rentsync-operator > /dev/null 2>&1; then fail "the role trusted itself"; fi
if STS_ACCOUNT=999999999999 run --apply > /dev/null 2>&1; then fail "ran against an AWS account the settings don't name"; fi
if RENTSYNC_SETTINGS="$work/missing.env" run > "$work/err" 2>&1; then fail "ran without a settings file"; fi
grep -q 'bootstrap-init.sh' "$work/err" || fail "a missing settings file did not point at bootstrap-init.sh"
if run --bogus > /dev/null 2>&1; then fail "accepted an unknown option"; fi
[ "$(mutations)" -eq 0 ] || fail "a refused run made changes"

# 3. Plan changes nothing and prints the profiles.
plan="$(EXISTING="" run)" || fail "plan failed"
[ "$(mutations)" -eq 0 ] || fail "plan mode made a mutating call"
grep -q '^+ aws iam create-role --role-name rentsync-operator --max-session-duration 3600 ' <<< "$plan" || fail "plan does not list the role"
grep -qx 'role_arn = arn:aws:iam::123456789012:role/rentsync-operator' <<< "$plan" || fail "plan does not print the profile"
grep -qx 'source_profile = rentsync-login' <<< "$plan" || fail "the profile has no source profile"
grep -qx 'region = eu-west-2' <<< "$plan" || fail "the profile has the wrong region"

# 4. Apply, then rerun.
EXISTING="" run --apply > /dev/null || fail "apply failed"
[ "$(calls create-policy)" -eq 1 ] || fail "expected the policy created"
grep -q 'create-role --role-name rentsync-operator --max-session-duration 3600 .*--assume-role-policy-document file://.*/trust.json --tags Key=rentsync:bootstrap,Value=true' \
  "$AWS_LOG" || fail "role created without its trust, one-hour limit or tag"
grep -q 'attach-role-policy --role-name rentsync-operator --policy-arn arn:aws:iam::123456789012:policy/rentsync-operator' "$AWS_LOG" \
  || fail "own policy not attached"
grep -q 'attach-role-policy --role-name rentsync-operator --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess' "$AWS_LOG" \
  || fail "ReadOnlyAccess not attached"
out="$(EXISTING="policy:rentsync-operator role:rentsync-operator" run --apply)" || fail "rerun failed"
[ "$(calls create-policy)" -eq 0 ] || fail "re-created the policy"
[ "$(calls create-role)" -eq 0 ] || fail "re-created the role"
[ "$(calls update-assume-role-policy)" -eq 1 ] || fail "did not refresh the trust"
grep -q 'policy rentsync-operator exists; not changed' <<< "$out" || fail "existing policy not reported"

# 5. An Access Analyzer ERROR blocks every change.
if FINDING=trust.json EXISTING="" run --apply > "$work/err" 2>&1; then fail "apply succeeded despite an ERROR"; fi
grep -q MALFORMED_ARN "$work/err" || fail "the finding was not shown"
[ "$(mutations)" -eq 0 ] || fail "a change was made despite an Access Analyzer ERROR"

# 6. What the policy grants.
policy="$work/out/operator/policy.json"
[ "$(jq -r '[.Statement[] | select(.Action == "kms:Decrypt")][0].Condition.StringLike["kms:EncryptionContext:PARAMETER_ARN"]' "$policy")" \
  = "arn:aws:ssm:eu-west-2:123456789012:parameter/rentsync/*/admin_token" ] || fail "decryption is not limited to admin tokens"
if jq -r '[.Statement[].Action] | flatten | .[]' "$policy" | grep -qE 'ec2:|Reboot|Stop|Put|Delete|Create|Update|\*'; then
  fail "the policy grants a change beyond running commands"
fi
[ "$(jq '[.Statement[] | select(.Effect != "Allow")] | length' "$policy")" -eq 0 ] || fail "unexpected statement effect"

# 7. Teardown, through a real terminal (script(1)); the numbers are fixed at 3 + 4.
deletes() { grep -cE '^iam (delete|detach)-' "$AWS_LOG" || true; }
teardown() { # answer
  : > "$AWS_LOG"
  printf '%s\n' "$1" | PATH="$work/bin:$PATH" RENTSYNC_IAM_OUT="$work/out" RENTSYNC_TEARDOWN_NUMBERS="3 4" \
    script -qec "bash $script --teardown" /dev/null
}
all="policy:rentsync-operator role:rentsync-operator"
out="$(EXISTING="$all" teardown 6 2>&1)" && fail "a wrong answer succeeded"
[ "$(deletes)" -eq 0 ] || fail "a wrong answer deleted something"
grep -q 'delete role rentsync-operator' <<< "$out" || fail "the plan does not list the role"
if printf '7\n' | EXISTING="$all" RENTSYNC_TEARDOWN_NUMBERS="3 4" run --teardown > "$work/err" 2>&1; then
  fail "teardown without a terminal succeeded"
fi
[ "$(deletes)" -eq 0 ] || fail "teardown without a terminal deleted something"

out="$(EXISTING="$all" teardown 7 2>&1)" || fail "teardown failed: $out"
grep -q '^iam detach-role-policy --role-name rentsync-operator --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess' "$AWS_LOG" \
  || fail "ReadOnlyAccess not detached"
grep -q '^iam delete-role --role-name rentsync-operator$' "$AWS_LOG" || fail "role not deleted"
grep -q '^iam delete-policy --policy-arn arn:aws:iam::123456789012:policy/rentsync-operator$' "$AWS_LOG" || fail "policy not deleted"
[ "$(grep -n '^iam delete-role ' "$AWS_LOG" | cut -d: -f1)" -lt "$(grep -n '^iam delete-policy ' "$AWS_LOG" | cut -d: -f1)" ] \
  || fail "the policy was deleted before the role"
[ "$(deletes)" -eq 5 ] || fail "expected 5 changes (2 detaches, role, old version, policy), got $(deletes)"
if SHARED_POLICY=1 EXISTING="$all" teardown 7 > "$work/err" 2>&1; then fail "teardown ran with a shared policy"; fi
[ "$(deletes)" -eq 0 ] || fail "a refused teardown deleted something"
grep -q 'Nothing to delete' <<< "$(EXISTING="" teardown 7 2>&1)" || fail "nothing to delete was not reported"

echo "PASS: bootstrap-operator"
