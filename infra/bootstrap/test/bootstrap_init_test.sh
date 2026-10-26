#!/usr/bin/env bash
# Test for bootstrap-init.sh (runbook §Bootstrap step 0). Answers come on stdin and a stub `gh`
# reports the repository's OIDC subject format, so no GitHub access is needed. Proves:
#   1. the answers, plus the subject prefix from GitHub, are saved as KEY='value' lines that the
#      other scripts' loader accepts, and the CloudShell block writes an identical copy;
#   2. an invalid answer is asked again, and the AMI may stay blank;
#   3. a rerun offers every saved value, so Enter keeps them all;
#   4. a repository with a custom OIDC subject template is refused, and nothing is written;
#   5. --ami sets only the AMI ID, without prompts or GitHub, and refuses a malformed ID or a
#      missing settings file.
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

# The CloudShell block writes every setting, so runbook commands that use the domain or the
# emails work there too, and works whether or not the repository is already cloned (a stub git
# stands in for GitHub).
block="$(sed -n '/^\[ -d /,/^EOF$/p' <<< "$out")"
cmp -s <(grep '^RENTSYNC_' <<< "$block") <(grep '^RENTSYNC_' "$RENTSYNC_SETTINGS") \
  || fail "the CloudShell block does not carry every setting: $block"
mkdir -p "$work/cloudshell" "$work/gitbin"
cat > "$work/gitbin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$GIT_LOG"
if [ "$1" = clone ]; then mkdir -p "$(basename "$2" .git)"; fi
STUB
chmod +x "$work/gitbin/git"
for pass in fresh existing; do
  (cd "$work/cloudshell" && PATH="$work/gitbin:$PATH" GIT_LOG="$work/git.log" bash -e <<< "$block") \
    || fail "the CloudShell block failed on a $pass clone"
  cmp -s <(grep '^RENTSYNC_' <<< "$block") "$work/cloudshell/example-app/.bootstrap/settings.env" \
    || fail "the CloudShell block did not write the settings on a $pass clone"
done
[ "$(grep -c '^git clone' "$work/git.log")" -eq 1 ] || fail "the CloudShell block cloned over an existing clone"

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

# 5. --ami sets only the AMI ID (the command step 1 prints): no prompts, no GitHub call.
before="$(cat "$RENTSYNC_SETTINGS")"
: > "$GH_LOG"
run_ami() { bash "$script" --ami "$@" < /dev/null; }
run_ami ami-0fedcba9876543210 > "$work/out" 2>&1 || fail "--ami failed"
grep -qx "RENTSYNC_AMI_ID='ami-0fedcba9876543210'" "$RENTSYNC_SETTINGS" || fail "--ami did not save the AMI"
[ "$(grep -v AMI "$RENTSYNC_SETTINGS")" = "$(grep -v AMI <<< "$before")" ] || fail "--ami changed another setting"
[ ! -s "$GH_LOG" ] || fail "--ami called GitHub"
if grep -q CloudShell "$work/out"; then fail "--ami printed the CloudShell block"; fi
before="$(cat "$RENTSYNC_SETTINGS")"
if run_ami ami-XYZ > /dev/null 2>&1; then fail "--ami accepted a malformed AMI ID"; fi
if run_ami > /dev/null 2>&1; then fail "--ami accepted no AMI ID"; fi
if bash "$script" --bogus < /dev/null > /dev/null 2>&1; then fail "accepted an unknown option"; fi
[ "$(cat "$RENTSYNC_SETTINGS")" = "$before" ] || fail "a refused --ami changed the settings file"
if RENTSYNC_SETTINGS="$work/none.env" run_ami ami-0fedcba9876543210 > /dev/null 2>&1; then
  fail "--ami ran without a settings file"
fi
[ ! -e "$work/none.env" ] || fail "--ami created a settings file on its own"

echo "PASS: bootstrap-init"
