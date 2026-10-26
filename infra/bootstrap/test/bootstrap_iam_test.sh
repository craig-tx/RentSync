#!/usr/bin/env bash
# Test for bootstrap-iam.sh (runbook §Bootstrap). A stub `aws` on PATH simulates IAM, STS and
# Access Analyzer and logs every call, so no cloud access is needed. Proves:
#   1. the render fills every <aws-account-id> placeholder with the AWS account ID from STS;
#      every GitHub trust uses the repository's immutable subject format;
#   2. a bad AWS account ID, or a placeholder left in a source file, fails before any change;
#   3. the default (plan) mode makes no mutating call;
#   4. --apply on an empty AWS account creates both providers and all four policies and roles;
#   5. --apply on a half-done AWS account skips what exists and never re-creates it;
#   6. an Access Analyzer ERROR stops the run before any change.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bootstrap-iam.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
# Stub state: $EXISTING lists "oidc:<host>", "policy:<name>" and "role:<name>" entries;
# $FINDING names a rendered file on which validate-policy reports an ERROR.
# $STS_ACCOUNT overrides the AWS account ID that STS reports.
cat > "$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$AWS_LOG"
has() { case " ${EXISTING:-} " in *" $1 "*) return 0 ;; esac; return 1; }
arg() { local want="$1"; shift; while [ $# -gt 1 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "sts get-caller-identity") echo "${STS_ACCOUNT:-123456789012}" ;;
  "accessanalyzer validate-policy")
    if [ -n "${FINDING:-}" ] && [[ "$(arg --policy-document "$@")" == *"/$FINDING" ]]; then
      printf 'ERROR\tMALFORMED_ARN\tThe ARN is malformed.\n'
    fi ;;
  "iam list-open-id-connect-providers")
    for h in app.terraform.io token.actions.githubusercontent.com; do
      has "oidc:$h" && printf 'arn:aws:iam::123456789012:oidc-provider/%s\t' "$h"
    done; echo ;;
  "iam get-open-id-connect-provider")
    case "$(arg --open-id-connect-provider-arn "$@")" in
      */app.terraform.io) echo aws.workload.identity ;;
      *) echo sts.amazonaws.com ;;
    esac ;;
  "iam get-policy")
    has "policy:$(arg --policy-arn "$@" | sed 's|.*/||')" || { echo "An error occurred (NoSuchEntity)" >&2; exit 254; } ;;
  "iam get-role")
    has "role:$(arg --role-name "$@")" || { echo "An error occurred (NoSuchEntity)" >&2; exit 254; } ;;
  *) ;;
esac
STUB
chmod +x "$work/bin/aws"

export AWS_LOG="$work/aws.log"
run() { : > "$AWS_LOG"; PATH="$work/bin:$PATH" RENTSYNC_IAM_OUT="$work/out" bash "$script" "$@"; }
mutations() { grep -cE '^iam (create|update|attach|add)-' "$AWS_LOG" || true; }
calls() { grep -c "^iam $1 " "$AWS_LOG" || true; }

# 1. The render, with the AWS account ID read from STS.
EXISTING="" run > /dev/null || fail "plan failed"
[ "$(find "$work/out" -name '*.json' | wc -l)" -eq 8 ] || fail "expected 8 rendered files"
if grep -l '<aws-account-id>' "$work/out"/*.json; then fail "a placeholder survived the render"; fi
grep -q 'arn:aws:iam::123456789012:oidc-provider/app.terraform.io' "$work/out/hcp-terraform-trust.json" \
  || fail "trust policy lacks the AWS account ID"
# The repository's tokens carry immutable subjects (contracts/bootstrap-iam.md); a trust in the
# older repo:craig-tx/RentSync: form would never match.
for f in "$work/out"/github-*-trust.json; do
  grep -q '"repo:craig-tx@16706018/RentSync@1427164274:' "$f" || fail "$(basename "$f") lacks the immutable subject"
  if grep -q 'repo:craig-tx/RentSync:' "$f"; then fail "$(basename "$f") uses the old subject format"; fi
done

# 2. Bad input.
if STS_ACCOUNT=12345 run > /dev/null 2>&1; then fail "accepted a short AWS account ID"; fi
if run --render-only 123456789012 > /dev/null 2>&1; then fail "accepted the removed --render-only"; fi
mkdir -p "$work/src"
cp "$here/../../../docs/deploy/iam"/*.json "$work/src/"
sed -i 's/us-east-1/<region>/' "$work/src/hcp-terraform-policy.json"
if RENTSYNC_IAM_SRC="$work/src" run --apply > /dev/null 2>&1; then
  fail "a leftover <region> placeholder did not fail the render"
fi
[ "$(mutations)" -eq 0 ] || fail "a failed render still made changes"

# 3. Plan on an empty AWS account: lists every change, makes none.
plan="$(EXISTING="" run)" || fail "plan failed"
[ "$(mutations)" -eq 0 ] || fail "plan mode made a mutating call"
[ "$(echo "$plan" | grep -c '^+ aws iam create-policy ')" -eq 4 ] || fail "plan does not list 4 create-policy"
grep -q '^+ aws iam create-open-id-connect-provider --url https://app.terraform.io' <<< "$plan" \
  || fail "plan does not list the HCP provider"
grep -q 'arn:aws:iam::123456789012:role/rentsync-github-actions-prod' <<< "$plan" \
  || fail "plan does not print the role ARNs"

# 4. Apply on an empty AWS account.
EXISTING="" run --apply > /dev/null || fail "apply failed"
[ "$(calls create-open-id-connect-provider)" -eq 2 ] || fail "expected 2 providers created"
[ "$(calls create-policy)" -eq 4 ] || fail "expected 4 policies created"
[ "$(calls create-role)" -eq 4 ] || fail "expected 4 roles created"
[ "$(calls attach-role-policy)" -eq 4 ] || fail "expected 4 attachments"
grep -q 'create-role --role-name rentsync-github-build --assume-role-policy-document file://.*/github-build-trust.json' \
  "$AWS_LOG" || fail "role created without its trust document"

# 5. Apply on a half-done AWS account: providers and the HCP pair exist.
half="oidc:app.terraform.io oidc:token.actions.githubusercontent.com policy:rentsync-hcp-terraform role:rentsync-hcp-terraform"
out="$(EXISTING="$half" run --apply)" || fail "apply on a half-done AWS account failed"
[ "$(calls create-open-id-connect-provider)" -eq 0 ] || fail "re-created a provider"
if grep -q 'create-policy --policy-name rentsync-hcp-terraform' "$AWS_LOG"; then fail "re-created an existing policy"; fi
if grep -q 'create-role --role-name rentsync-hcp-terraform' "$AWS_LOG"; then fail "re-created an existing role"; fi
grep -q 'update-assume-role-policy --role-name rentsync-hcp-terraform' "$AWS_LOG" \
  || fail "did not refresh the existing role's trust policy"
[ "$(calls create-policy)" -eq 3 ] || fail "expected the other 3 policies created"
grep -q 'policy rentsync-hcp-terraform exists; not changed' <<< "$out" || fail "existing policy not reported"

# 6. An Access Analyzer ERROR blocks every change.
if FINDING=hcp-terraform-policy.json EXISTING="" run --apply > "$work/err.out" 2>&1; then
  fail "apply succeeded despite an Access Analyzer ERROR"
fi
grep -q MALFORMED_ARN "$work/err.out" || fail "the finding was not shown"
[ "$(mutations)" -eq 0 ] || fail "a change was made despite an Access Analyzer ERROR"

echo "PASS: bootstrap-iam"
