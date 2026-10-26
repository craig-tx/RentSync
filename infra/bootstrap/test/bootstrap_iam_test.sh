#!/usr/bin/env bash
# Test for bootstrap-iam.sh (runbook §Bootstrap). A stub `aws` on PATH simulates IAM, STS and
# Access Analyzer and logs every call, so no cloud access is needed. Proves:
#   1. the render fills every placeholder from the settings file, for any deployment;
#      every GitHub trust uses the subject prefix GitHub reported, whatever its format;
#   2. a bad or mismatched AWS account ID, a missing settings file, or a placeholder left in a
#      source file, fails before any change;
#   3. the default (plan) mode makes no mutating call, and ends with the current AMI ID and the
#      command that saves it; a failed or malformed AMI lookup warns without failing the run;
#   4. --apply on an empty AWS account creates both providers and all four policies and roles;
#   5. --apply on a half-done AWS account skips what exists and never re-creates it;
#   6. an Access Analyzer ERROR stops the run before any change;
#   7. --teardown (at a terminal, after the sum) deletes exactly the bootstrap's roles, policies
#      and tagged providers, keeps adopted ones, and refuses on a wrong answer, no terminal,
#      live infrastructure or a shared policy.
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
  # Teardown reads. A role has its own policy attached plus one inline policy; a policy has one
  # old version; $SHARED_POLICY attaches rentsync-github-build to a user as well.
  "iam list-attached-role-policies") echo "arn:aws:iam::123456789012:policy/$(arg --role-name "$@")" ;;
  "iam list-role-policies") echo "inline-extra" ;;
  "iam list-entities-for-policy")
    name="$(arg --policy-arn "$@" | sed 's|.*/||')"
    printf '%s' "$name"; [ -n "${SHARED_POLICY:-}" ] && [ "$name" = rentsync-github-build ] && printf '\tsomeone'; echo ;;
  "iam list-policy-versions") echo v1 ;;
  "iam list-open-id-connect-provider-tags")
    case " ${TAGGED:-} " in *" $(arg --open-id-connect-provider-arn "$@" | sed 's|.*/||') "*) echo true ;; *) echo ;; esac ;;
  "ec2 describe-instances") echo "${INSTANCES:-}" ;;
  "ec2 describe-volumes") echo "${VOLUMES:-}" ;;
  "ce list-cost-allocation-tags") echo "${COST_TAG:-None}" ;;
  "ssm get-parameter")
    [ -n "${AMI_ERROR:-}" ] && { echo "An error occurred (ParameterNotFound)" >&2; exit 254; }
    echo "${AMI:-ami-0123456789abcdef0}" ;;
  *) ;;
esac
STUB
chmod +x "$work/bin/aws"

# A deployment that is not the reference one, in a region other than us-east-1, with the
# classic (mutable) GitHub subject format.
SUBJECT="repo:example-owner/example-app"
cat > "$work/settings.env" <<EOF
RENTSYNC_AWS_ACCOUNT_ID='123456789012'
RENTSYNC_AWS_REGION='eu-west-2'
RENTSYNC_HCP_ORG='example-org'
RENTSYNC_GITHUB_SUBJECT='$SUBJECT'
EOF

export AWS_LOG="$work/aws.log" RENTSYNC_SETTINGS="$work/settings.env"
run() { : > "$AWS_LOG"; PATH="$work/bin:$PATH" RENTSYNC_IAM_OUT="$work/out" bash "$script" "$@"; }
mutations() { grep -cE '^iam (create|update|attach|add)-' "$AWS_LOG" || true; }
calls() { grep -c "^iam $1 " "$AWS_LOG" || true; }

# 1. The render fills every placeholder from the settings.
EXISTING="" run > /dev/null || fail "plan failed"
[ "$(find "$work/out" -name '*.json' | wc -l)" -eq 8 ] || fail "expected 8 rendered files"
if grep -l '<[a-z-]*>' "$work/out"/*.json; then fail "a placeholder survived the render"; fi
grep -q 'arn:aws:iam::123456789012:oidc-provider/app.terraform.io' "$work/out/hcp-terraform-trust.json" \
  || fail "trust policy lacks the AWS account ID"
grep -q '"aws:RequestedRegion": "eu-west-2"' "$work/out/hcp-terraform-policy.json" || fail "region not filled in"
grep -q '"organization:example-org:project:RentSync:' "$work/out/hcp-terraform-trust.json" || fail "HCP Terraform organization not filled in"
# Each GitHub trust matches the subject prefix GitHub reported (contracts/bootstrap-iam.md).
for f in "$work/out"/github-*-trust.json; do
  grep -q "\"$SUBJECT:" "$f" || fail "$(basename "$f") lacks the settings' GitHub subject"
done
if grep -rqE 'craig|us-east-1' "$work/out"; then fail "a reference-deployment value is hard-coded in a template"; fi

# 2. Bad input.
if STS_ACCOUNT=12345 run > /dev/null 2>&1; then fail "accepted a short AWS account ID"; fi
if STS_ACCOUNT=999999999999 run > /dev/null 2>&1; then fail "ran against an AWS account the settings don't name"; fi
if RENTSYNC_SETTINGS="$work/missing.env" run > "$work/err" 2>&1; then fail "ran without a settings file"; fi
grep -q 'bootstrap-init.sh' "$work/err" || fail "a missing settings file did not point at bootstrap-init.sh"
if run --render-only 123456789012 > /dev/null 2>&1; then fail "accepted the removed --render-only"; fi
mkdir -p "$work/src"
cp "$here/../../../docs/deploy/iam"/*.json "$work/src/"
sed 's/RentSync/<project>/' "$here/../../../docs/deploy/iam/hcp-terraform-trust.json" > "$work/src/hcp-terraform-trust.json"
if RENTSYNC_IAM_SRC="$work/src" run --apply > /dev/null 2>&1; then
  fail "a leftover <project> placeholder did not fail the render"
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
# The AMI: read in the settings' region, printed with the
# command that saves it on the operator's machine.
grep -qx 'ssm get-parameter --region eu-west-2 --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 --query Parameter.Value --output text' \
  "$AWS_LOG" || fail "the AMI was not read from the Amazon Linux 2023 arm64 parameter in the settings' region"
grep -q '^  bash infra/bootstrap/bootstrap-init.sh --ami ami-0123456789abcdef0$' <<< "$plan" \
  || fail "plan does not print the command that saves the AMI"
out="$(AMI="not-an-ami" EXISTING="" run 2>&1)" || fail "a bad AMI value failed the plan"
if grep -q -- '--ami not-an-ami' <<< "$out"; then fail "printed a malformed AMI ID as the one to save"; fi
grep -q 'could not read the AMI' <<< "$out" || fail "a malformed AMI ID was not reported"
out="$(AMI_ERROR=1 EXISTING="" run 2>&1)" || fail "a failed AMI lookup failed the plan"
grep -q 'could not read the AMI' <<< "$out" || fail "a failed AMI lookup was not reported"

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

# 7. Providers the bootstrap creates are tagged, so teardown can tell them from adopted ones.
EXISTING="" run --apply > /dev/null || fail "apply failed"
[ "$(grep -c 'create-open-id-connect-provider .*--tags Key=rentsync:bootstrap,Value=true' "$AWS_LOG")" -eq 2 ] \
  || fail "created providers are not tagged"

# 8. Teardown. The answer goes through a real terminal (script(1)); the numbers are fixed at 3 + 4.
deletes() { grep -cE '^(iam (delete|detach)-|ce update-)' "$AWS_LOG" || true; }
teardown() { # answer; runs --teardown at a terminal
  : > "$AWS_LOG"
  printf '%s\n' "$1" | PATH="$work/bin:$PATH" RENTSYNC_IAM_OUT="$work/out" RENTSYNC_TEARDOWN_NUMBERS="3 4" \
    script -qec "bash $script --teardown" /dev/null
}
all="oidc:app.terraform.io oidc:token.actions.githubusercontent.com"
for s in hcp-terraform github-build github-actions github-actions-prod; do all="$all policy:rentsync-$s role:rentsync-$s"; done

out="$(EXISTING="$all" TAGGED="app.terraform.io" COST_TAG=Active teardown 6 2>&1)" && fail "a wrong answer succeeded"
[ "$(deletes)" -eq 0 ] || fail "a wrong answer deleted something"
grep -q 'delete role rentsync-github-actions-prod' <<< "$out" || fail "the plan does not list the roles"
grep -q 'permanently deletes' <<< "$out" || fail "no warning before the question"
# The right answer arrives, but not from a terminal, so it must still be refused.
if printf '7\n' | EXISTING="$all" RENTSYNC_TEARDOWN_NUMBERS="3 4" run --teardown > "$work/err" 2>&1; then fail "teardown without a terminal succeeded"; fi
grep -q 'No interactive terminal' "$work/err" || fail "no-terminal refusal not explained"
[ "$(deletes)" -eq 0 ] || fail "teardown without a terminal deleted something"

out="$(EXISTING="$all" TAGGED="app.terraform.io" COST_TAG=Active teardown 7 2>&1)" || fail "teardown failed: $out"
for s in hcp-terraform github-build github-actions github-actions-prod; do
  grep -q "^iam detach-role-policy --role-name rentsync-$s " "$AWS_LOG" || fail "rentsync-$s not detached"
  grep -q "^iam delete-role-policy --role-name rentsync-$s --policy-name inline-extra" "$AWS_LOG" || fail "rentsync-$s inline policy kept"
  grep -q "^iam delete-role --role-name rentsync-$s$" "$AWS_LOG" || fail "role rentsync-$s not deleted"
  grep -q "^iam delete-policy-version --policy-arn arn:aws:iam::123456789012:policy/rentsync-$s --version-id v1" "$AWS_LOG" \
    || fail "old version of rentsync-$s not deleted"
  grep -q "^iam delete-policy --policy-arn arn:aws:iam::123456789012:policy/rentsync-$s$" "$AWS_LOG" || fail "policy rentsync-$s not deleted"
done
# Roles go before their policies, and nothing but exact bootstrap names is touched.
[ "$(grep -n '^iam delete-role --role-name rentsync-hcp-terraform' "$AWS_LOG" | cut -d: -f1)" -lt \
  "$(grep -n '^iam delete-policy --policy-arn .*rentsync-hcp-terraform' "$AWS_LOG" | cut -d: -f1)" ] || fail "a policy was deleted before its role"
grep -q 'delete-open-id-connect-provider --open-id-connect-provider-arn .*app.terraform.io' "$AWS_LOG" || fail "tagged provider kept"
if grep -q 'delete-open-id-connect-provider .*token.actions' "$AWS_LOG"; then fail "an adopted provider was deleted"; fi
grep -q 'kept: OIDC provider token.actions.githubusercontent.com' <<< "$out" || fail "the adopted provider was not reported"
grep -q 'TagKey=DeploymentId,Status=Inactive' "$AWS_LOG" || fail "the cost allocation tag was not deactivated"
[ "$(deletes)" -eq 22 ] || fail "expected 22 changes (4 roles x 3, 4 policies x 2, 1 provider, 1 tag), got $(deletes)"

# Refusals: running infrastructure, a policy shared with something else, and nothing left.
if INSTANCES="i-0abc" EXISTING="$all" teardown 7 > "$work/err" 2>&1; then fail "teardown ran with live instances"; fi
grep -q 'Destroy it first' "$work/err" || fail "the live-infrastructure refusal was not explained"
if SHARED_POLICY=1 EXISTING="$all" teardown 7 > "$work/err" 2>&1; then fail "teardown ran with a shared policy"; fi
[ "$(deletes)" -eq 0 ] || fail "a refused teardown deleted something"
grep -q 'Nothing to delete' <<< "$(EXISTING="" teardown 7 2>&1)" || fail "an empty AWS account was not reported as nothing to delete"

echo "PASS: bootstrap-iam"
