#!/usr/bin/env bash
# Runbook §Bootstrap step 0 (feature 002): asks for every deployment setting and writes them to
# .bootstrap/settings.env (gitignored, or $RENTSYNC_SETTINGS), which the other bootstrap scripts
# read. Run it on your machine from Git Bash; it needs the gh CLI to read the repository's OIDC
# subject format.
#
#   bootstrap-init.sh
#
# Rerun it any time. Each prompt offers the current value, so Enter keeps it. Nothing secret is
# asked for: bootstrap-hcp.rb prompts for the OpenObserve password and generates the admin tokens.
# The file holds the AWS account ID, so it never goes into the repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=infra/bootstrap/settings.sh
. "$here/settings.sh"

die() { echo "error: $*" >&2; exit 1; }

if [ -f "$settings_file" ]; then
  load_settings
  echo "Updating $settings_file. Press Enter to keep a value in brackets."
else
  echo "Writing $settings_file."
fi

ask() { # setting, prompt, regex, description of a valid answer, default when unset
  local key="$1" prompt="$2" re="$3" valid="$4" def="${!1:-${5:-}}" answer
  while true; do
    read -r -p "$prompt${def:+ [$def]}: " answer || die "input ended before $key was answered"
    answer="${answer%$'\r'}"
    answer="${answer:-$def}"
    if [[ "$answer" =~ $re ]]; then
      printf -v "$key" '%s' "$answer"
      return
    fi
    echo "  expected $valid" >&2
  done
}

email='^[^@[:space:]"'\'']+@[^@[:space:]"'\'']+\.[^@[:space:]"'\'']+$'
origin="$(git -C "$here" remote get-url origin 2> /dev/null || true)"
[[ "$origin" =~ github\.com[:/]([^/]+/[^/]+)$ ]] && origin="${BASH_REMATCH[1]%.git}" || origin=""

ask RENTSYNC_AWS_ACCOUNT_ID "AWS account ID" '^[0-9]{12}$' "12 digits (AWS console, top right)"
ask RENTSYNC_AWS_REGION "AWS region" '^[a-z]{2}(-[a-z]+)+-[0-9]$' "an AWS region such as us-east-1" us-east-1
ask RENTSYNC_AWS_AZ "AWS availability zone for every host" "^${RENTSYNC_AWS_REGION}[a-z]\$" \
  "a zone in $RENTSYNC_AWS_REGION, such as ${RENTSYNC_AWS_REGION}a" "${RENTSYNC_AWS_REGION}a"
ask RENTSYNC_HCP_ORG "HCP Terraform organization" '^[A-Za-z0-9_-]+$' "letters, digits, - and _"
ask RENTSYNC_GITHUB_REPO "GitHub repository (owner/name)" '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' "owner/name" "$origin"
ask RENTSYNC_DOMAIN "Domain the hosts are served under (pms., pms-staging. and telemetry.<domain>)" \
  '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' "a lowercase domain such as example.com"
ask RENTSYNC_ACME_EMAIL "Let's Encrypt contact email" "$email" "an email address"
ask RENTSYNC_OPENOBSERVE_EMAIL "OpenObserve sign-in email" "$email" "an email address"
ask RENTSYNC_BUDGET_EMAIL "AWS budget alert email" "$email" "an email address"
ask RENTSYNC_AMI_ID "Amazon Linux 2023 arm64 AMI ID (blank for now: runbook step 2 prints it)" \
  '^(ami-[0-9a-f]{8,17})?$' "ami- and 8 to 17 hex digits, or blank"

# GitHub Actions tokens carry this prefix in their sub claim. The IAM trust policies match it
# exactly, so it is read from GitHub, never assumed (contracts/bootstrap-iam.md).
command -v gh > /dev/null || die "gh not found on this bash's PATH. On Windows, run this from Git Bash, not WSL"
oidc="$(gh api "repos/$RENTSYNC_GITHUB_REPO/actions/oidc/customization/sub" \
  --jq '"\(.use_default) \(.sub_claim_prefix // "")"')" \
  || die "could not read $RENTSYNC_GITHUB_REPO's OIDC subject format; check the name and run gh auth login"
if [ "${oidc%% *}" != "true" ]; then
  die "$RENTSYNC_GITHUB_REPO uses a custom OIDC subject template, which the trust policies don't support"
fi
RENTSYNC_GITHUB_SUBJECT="${oidc#* }"
[ -n "$RENTSYNC_GITHUB_SUBJECT" ] || RENTSYNC_GITHUB_SUBJECT="repo:$RENTSYNC_GITHUB_REPO"
[[ "$RENTSYNC_GITHUB_SUBJECT" =~ ^repo:[A-Za-z0-9@._/-]+$ ]] \
  || die "unexpected OIDC subject prefix from GitHub: $RENTSYNC_GITHUB_SUBJECT"

keys="RENTSYNC_AWS_ACCOUNT_ID RENTSYNC_AWS_REGION RENTSYNC_AWS_AZ RENTSYNC_HCP_ORG RENTSYNC_GITHUB_REPO
RENTSYNC_GITHUB_SUBJECT RENTSYNC_DOMAIN RENTSYNC_ACME_EMAIL RENTSYNC_OPENOBSERVE_EMAIL RENTSYNC_BUDGET_EMAIL
RENTSYNC_AMI_ID"
cloudshell_keys="RENTSYNC_AWS_ACCOUNT_ID RENTSYNC_AWS_REGION RENTSYNC_HCP_ORG RENTSYNC_GITHUB_SUBJECT"
lines() { local key; for key in $1; do printf "%s='%s'\n" "$key" "${!key}"; done; }

mkdir -p "$(dirname "$settings_file")"
{
  echo "# RentSync deployment settings, written by infra/bootstrap/bootstrap-init.sh. Not committed."
  lines "$keys"
} > "$settings_file.tmp"
chmod 600 "$settings_file.tmp" 2> /dev/null || true
mv "$settings_file.tmp" "$settings_file"

echo
echo "Saved $settings_file."
echo
echo "For step 1, paste this into AWS CloudShell. It clones the repository, or updates an existing"
echo "clone, and writes the four settings that step needs:"
echo
repo_dir="${RENTSYNC_GITHUB_REPO#*/}"
echo "[ -d $repo_dir ] || git clone https://github.com/$RENTSYNC_GITHUB_REPO.git"
echo "cd $repo_dir && git pull --ff-only && mkdir -p .bootstrap && cat > .bootstrap/settings.env <<'EOF'"
lines "$cloudshell_keys"
echo "EOF"
if [ -z "$RENTSYNC_AMI_ID" ]; then
  echo
  echo "The AMI ID is blank: rerun this script after step 2, or pass --ami to bootstrap-hcp.rb."
fi
