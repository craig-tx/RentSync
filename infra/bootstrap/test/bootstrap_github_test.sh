#!/usr/bin/env bash
# Test for bootstrap-github.sh (runbook §Bootstrap step 3). A stub `gh` on PATH serves GitHub API
# responses from JSON files and logs every write, so no GitHub access is needed. GETs run the
# script's real --jq expressions through jq. Proves:
#   1. bad arguments fail before any API call;
#   2. the default (plan) mode on an empty repository lists every change and makes none;
#   3. --apply on an empty repository makes exactly those changes;
#   4. a repository that already matches gets no changes;
#   5. drift is corrected: a differing variable is set again, an extra deployment branch is
#      removed, and adding a reviewer keeps the existing one;
#   6. an API error other than 404 stops the run;
#   7. --teardown (at a terminal, after the sum) deletes the variables and Environments, keeps
#      secret scanning, and deletes nothing on a wrong answer or without a terminal.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bootstrap-github.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
# Stub state: $GH_STATE/<path with / as __>.json is the GET response for that path; a missing
# file is a 404. A path listed in $GH_STATE/FAIL returns HTTP 500.
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" != "-X" ]; then
  file="$GH_STATE/${2//\//__}.json"
  if [ -f "$GH_STATE/FAIL" ] && grep -qxF "$2" "$GH_STATE/FAIL"; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
  [ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  jq -r "$4" "$file"
  exit
fi
echo "$*" >> "$GH_LOG"
prev=""
for a in "$@"; do [ "$prev" = "--input" ] && echo "  body $(cat "$a")" >> "$GH_LOG"; prev="$a"; done
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_LOG="$work/gh.log" GH_STATE="$work/state" RENTSYNC_SETTINGS="$work/settings.env"
cat > "$RENTSYNC_SETTINGS" <<'EOF'
RENTSYNC_AWS_ACCOUNT_ID='123456789012'
RENTSYNC_AWS_REGION='eu-west-2'
RENTSYNC_GITHUB_REPO='example-owner/example-app'
RENTSYNC_DOMAIN='example.com'
EOF

R="repos/example-owner/example-app"
put() { mkdir -p "$GH_STATE"; echo "$2" > "$GH_STATE/${1//\//__}.json"; }
reset() { rm -rf "$GH_STATE" "$GH_LOG"; mkdir -p "$GH_STATE"; : > "$GH_LOG"; }
run() { bash "$script" "$@"; }
writes() { grep -c . "$GH_LOG" | tr -d ' ' || true; }
ACCT=123456789012

# A repository where everything already matches. Callers modify it to make drift.
matching() {
  reset
  put "$R/actions/variables/AWS_BUILD_ROLE_ARN" "{\"value\":\"arn:aws:iam::$ACCT:role/rentsync-github-build\"}"
  put "$R/actions/variables/AWS_ROLE_ARN" "{\"value\":\"arn:aws:iam::$ACCT:role/rentsync-github-actions\"}"
  put "$R/actions/variables/AWS_REGION" '{"value":"eu-west-2"}'
  for env in dev-staging prod-us; do
    put "$R/environments/$env" '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true},"protection_rules":[]}'
    put "$R/environments/$env/deployment-branch-policies" '{"branch_policies":[{"id":7,"name":"main","type":"branch"}]}'
  done
  put "$R/environments/dev-staging/variables/SITE_URL" '{"value":"https://pms-staging.example.com"}'
  put "$R/environments/prod-us/variables/SITE_URL" '{"value":"https://pms.example.com"}'
  put "$R/environments/prod-us/variables/AWS_ROLE_ARN" "{\"value\":\"arn:aws:iam::$ACCT:role/rentsync-github-actions-prod\"}"
  put "$R" '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
}

# 1. Bad arguments.
reset
if RENTSYNC_SETTINGS="$work/missing.env" run > "$work/err" 2>&1; then fail "ran without a settings file"; fi
grep -q bootstrap-init.sh "$work/err" || fail "a missing settings file did not point at bootstrap-init.sh"
if run --aws-account 12345 > /dev/null 2>&1; then fail "accepted a short AWS account ID"; fi
if run --aws-account $ACCT --ecr-repository-url 999999999999.dkr.ecr.eu-west-2.amazonaws.com/x > /dev/null 2>&1; then
  fail "accepted an ECR URL from another AWS account"
fi
if run --aws-account $ACCT --bogus > /dev/null 2>&1; then fail "accepted an unknown option"; fi
[ "$(writes)" -eq 0 ] || fail "bad arguments made a write"

# 2. Plan on an empty repository (its security settings are off).
reset
put "$R" '{"security_and_analysis":{"secret_scanning":{"status":"disabled"},"secret_scanning_push_protection":{"status":"disabled"}}}'
plan="$(run)" || fail "plan failed"
[ "$(writes)" -eq 0 ] || fail "plan mode made a write"
[ "$(grep -c '^+ ' <<< "$plan")" -eq 11 ] || fail "plan should list 11 changes: $plan"
grep -qF "+ set repository variable AWS_BUILD_ROLE_ARN = arn:aws:iam::$ACCT:role/rentsync-github-build" <<< "$plan" \
  || fail "plan lacks the build role variable"
grep -qF "+ set prod-us Environment variable AWS_ROLE_ARN = arn:aws:iam::$ACCT:role/rentsync-github-actions-prod" <<< "$plan" \
  || fail "plan lacks the prod-us role override"
grep -q 'rerun with --ecr-repository-url' <<< "$plan" || fail "plan does not mention ECR_REPOSITORY_URL"
# --aws-account still overrides the settings.
grep -qF "arn:aws:iam::210987654321:role/rentsync-github-build" <<< "$(run --aws-account 210987654321)" \
  || fail "--aws-account did not override the settings"

# 3. Apply on the same empty repository.
run --apply > /dev/null || fail "apply failed"
[ "$(grep -c 'variable set' "$GH_LOG")" -eq 6 ] || fail "expected 6 variables set"
grep -q 'variable set AWS_ROLE_ARN --repo example-owner/example-app --body arn:aws:iam::123456789012:role/rentsync-github-actions-prod --env prod-us' "$GH_LOG" \
  || fail "the prod-us override was not set on the Environment"
[ "$(grep -c "^api -X PUT $R/environments/" "$GH_LOG")" -eq 2 ] || fail "expected 2 Environments created"
grep -q '"custom_branch_policies":true' "$GH_LOG" || fail "Environments not restricted to custom branches"
[ "$(grep -c 'deployment-branch-policies -f name=main -f type=branch' "$GH_LOG")" -eq 2 ] || fail "expected main allowed twice"
grep -q "^api -X PATCH $R --input" "$GH_LOG" || fail "secret scanning not turned on"

# 4. Everything already matches.
matching
out="$(run --apply)" || fail "apply on a matching repository failed"
[ "$(writes)" -eq 0 ] || fail "a matching repository got writes: $(cat "$GH_LOG")"
grep -q 'No changes' <<< "$out" || fail "no-change run not reported"

# 5. Drift.
matching
put "$R/actions/variables/AWS_REGION" '{"value":"us-west-2"}'
put "$R/environments/prod-us" '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers","reviewers":[{"type":"Team","reviewer":{"id":5}}]}]}'
put "$R/environments/dev-staging/deployment-branch-policies" '{"branch_policies":[{"id":7,"name":"main","type":"branch"},{"id":9,"name":"feature/*","type":"branch"}]}'
put "users/octo" '{"id":42}'
out="$(run --prod-reviewer octo --ecr-repository-url $ACCT.dkr.ecr.eu-west-2.amazonaws.com/shared-us/mock_pms --apply)" \
  || fail "apply with drift failed"
grep -q 'variable set AWS_REGION --repo example-owner/example-app --body eu-west-2$' "$GH_LOG" || fail "differing AWS_REGION not set again"
grep -q "variable set ECR_REPOSITORY_URL --repo example-owner/example-app --body $ACCT.dkr.ecr.eu-west-2.amazonaws.com/shared-us/mock_pms" "$GH_LOG" \
  || fail "ECR_REPOSITORY_URL not set"
grep -q "^api -X DELETE $R/environments/dev-staging/deployment-branch-policies/9$" "$GH_LOG" \
  || fail "extra deployment branch not removed"
if grep -q "deployment-branch-policies/7" "$GH_LOG"; then fail "removed the main policy"; fi
grep -qF '"reviewers":[{"type":"Team","id":5},{"type":"User","id":42}]' "$GH_LOG" \
  || fail "adding a reviewer dropped the existing one: $(cat "$GH_LOG")"
if grep -q "PUT $R/environments/dev-staging" "$GH_LOG"; then fail "touched a matching Environment"; fi
[ "$(writes)" -eq 5 ] || fail "expected 4 writes and 1 body for drift: $(cat "$GH_LOG")"

# 6. A server error stops the run.
matching
echo "$R/environments/prod-us" > "$GH_STATE/FAIL"
if run --apply > /dev/null 2> "$work/err"; then fail "a server error did not stop the run"; fi
grep -q 'HTTP 500' "$work/err" || fail "the server error was not shown"

# 7. Teardown, answered through a real terminal (script(1)) with the numbers fixed at 3 + 4.
teardown() { # answer
  : > "$GH_LOG"
  printf '%s
' "$1" | RENTSYNC_TEARDOWN_NUMBERS="3 4" script -qec "bash $script --teardown" /dev/null
}
matching
out="$(teardown 8 2>&1)" && fail "a wrong answer succeeded"
[ "$(writes)" -eq 0 ] || fail "a wrong answer deleted something"
grep -q 'delete Environment prod-us' <<< "$out" || fail "the plan does not list the Environments"
grep -q 'permanently deletes' <<< "$out" || fail "no warning before the question"
# The right answer arrives, but not from a terminal, so it must still be refused.
if printf '7\n' | RENTSYNC_TEARDOWN_NUMBERS="3 4" run --teardown > "$work/err" 2>&1; then fail "teardown without a terminal succeeded"; fi
grep -q 'No interactive terminal' "$work/err" || fail "no-terminal refusal not explained"
[ "$(writes)" -eq 0 ] || fail "teardown without a terminal deleted something"
out="$(teardown 7 2>&1)" || fail "teardown failed: $out"
for name in AWS_BUILD_ROLE_ARN AWS_ROLE_ARN AWS_REGION; do
  grep -qx "variable delete $name --repo example-owner/example-app" "$GH_LOG" || fail "$name not deleted"
done
for env in dev-staging prod-us; do
  grep -qx "api -X DELETE $R/environments/$env" "$GH_LOG" || fail "Environment $env not deleted"
done
[ "$(writes)" -eq 5 ] || fail "expected 5 deletions: $(cat "$GH_LOG")"
if grep -q PATCH "$GH_LOG"; then fail "teardown touched secret scanning"; fi
grep -q 'kept: secret scanning' <<< "$out" || fail "kept secret scanning not reported"
reset
put "$R" '{"security_and_analysis":{}}'
grep -q 'Nothing to delete' <<< "$(teardown 7 2>&1)" || fail "an empty repository was not reported as nothing to delete"

echo "PASS: bootstrap-github"
