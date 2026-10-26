#!/usr/bin/env bash
# Test for bootstrap-init.sh (runbook §Bootstrap step 0). Answers come on stdin and a stub `gh`
# reports the repository's OIDC subject format, so no GitHub access is needed. Proves:
#   1. the answers, plus the subject prefix from GitHub, are saved as KEY='value' lines that the
#      other scripts' loader accepts, and the CloudShell block carries only what step 1 needs;
#   2. an invalid answer is asked again, and the AMI may stay blank;
#   3. a rerun offers every saved value, so Enter keeps them all;
#   4. a repository with a custom OIDC subject template is refused, and nothing is written.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../bootstrap-init.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin"
# $OIDC is the stub's answer to the OIDC customization endpoint, after the script's --jq.
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ "$2" = "repos/example-owner/example-app/actions/oidc/customization/sub" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
echo "$OIDC"
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_LOG="$work/gh.log" RENTSYNC_SETTINGS="$work/settings.env"
export OIDC="true repo:example-owner@111/example-app@222"
run() { bash "$script"; }

# 1 and 2. First run. "12345" and "Example.COM" are rejected and asked again; the AMI is blank.
answers="12345
123456789012
eu-west-2

example-org
example-owner/example-app
Example.COM
example.com
acme@example.com
oo@example.com
budget@example.com

"
out="$(printf '%s' "$answers" | run 2>&1)" || fail "first run failed: $out"
grep -q 'expected 12 digits' <<< "$out" || fail "a short AWS account ID was not asked again"
grep -q 'expected a lowercase domain' <<< "$out" || fail "an uppercase domain was not asked again"
expected="# RentSync deployment settings, written by infra/bootstrap/bootstrap-init.sh. Not committed.
RENTSYNC_AWS_ACCOUNT_ID='123456789012'
RENTSYNC_AWS_REGION='eu-west-2'
RENTSYNC_AWS_AZ='eu-west-2a'
RENTSYNC_HCP_ORG='example-org'
RENTSYNC_GITHUB_REPO='example-owner/example-app'
RENTSYNC_GITHUB_SUBJECT='repo:example-owner@111/example-app@222'
RENTSYNC_DOMAIN='example.com'
RENTSYNC_ACME_EMAIL='acme@example.com'
RENTSYNC_OPENOBSERVE_EMAIL='oo@example.com'
RENTSYNC_BUDGET_EMAIL='budget@example.com'
RENTSYNC_AMI_ID=''"
[ "$(cat "$RENTSYNC_SETTINGS")" = "$expected" ] || fail "settings file differs: $(cat "$RENTSYNC_SETTINGS")"
grep -q 'The AMI ID is blank' <<< "$out" || fail "a blank AMI was not pointed out"

# The loader the other scripts use accepts the file.
(
  # shellcheck source=infra/bootstrap/settings.sh
  . "$here/../settings.sh"
  load_settings
  [ "$RENTSYNC_GITHUB_SUBJECT" = "repo:example-owner@111/example-app@222" ] || fail "loader read the wrong subject"
) || exit 1

# The CloudShell block clones the repository and writes only step 1's four settings.
block="$(sed -n '/^git clone /,/^EOF$/p' <<< "$out")"
grep -q '^git clone https://github.com/example-owner/example-app.git' <<< "$block" || fail "no clone in the CloudShell block"
[ "$(grep -c "^RENTSYNC_" <<< "$block")" -eq 4 ] || fail "the CloudShell block should carry 4 settings: $block"
if grep -q EMAIL <<< "$block"; then fail "the CloudShell block carries emails it doesn't need"; fi

# 3. A rerun with only Enter keeps every value; one answer changes the AMI.
before="$(cat "$RENTSYNC_SETTINGS")"
printf '\n\n\n\n\n\n\n\n\nami-0123456789abcdef0\n' | run > /dev/null 2>&1 || fail "rerun failed"
[ "$(grep -v AMI "$RENTSYNC_SETTINGS")" = "$(grep -v AMI <<< "$before")" ] || fail "Enter did not keep a value"
grep -qx "RENTSYNC_AMI_ID='ami-0123456789abcdef0'" "$RENTSYNC_SETTINGS" || fail "the AMI was not saved on rerun"

# 4. A custom OIDC subject template is refused, and the settings file is untouched.
before="$(cat "$RENTSYNC_SETTINGS")"
if printf '\n\n\n\n\n\n\n\n\n\n' | OIDC="false " run > "$work/err" 2>&1; then fail "accepted a custom OIDC subject template"; fi
grep -q 'custom OIDC subject template' "$work/err" || fail "the custom template was not explained"
[ "$(cat "$RENTSYNC_SETTINGS")" = "$before" ] || fail "a refused run changed the settings file"

echo "PASS: bootstrap-init"
