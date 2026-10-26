#!/usr/bin/env bash
# Runbook §Bootstrap step 4 (feature 002): the GitHub repository variables, the dev-staging and
# prod-us Environments, and secret scanning, through the GitHub API with the gh CLI. Run it from
# your machine after `gh auth login`, once the IAM roles exist (step 1). The repository, AWS
# account, AWS region and domain come from .bootstrap/settings.env (bootstrap-init.sh).
#
#   bootstrap-github.sh [options]          print the plan; changes nothing
#   bootstrap-github.sh [options] --apply  the same, then make the changes
#   bootstrap-github.sh --teardown         list what the bootstrap set, then delete it after a
#                                          typed confirmation (constitution: Reversible bootstrap)
#
# Options:
#   --aws-account ID          override the settings' AWS account ID
#   --ecr-repository-url URL  also set ECR_REPOSITORY_URL (rerun after the first shared-us apply)
#   --prod-reviewer LOGIN     add a GitHub user as the prod-us required reviewer (task T074)
#
# Only non-secret values are set: role ARNs, the AWS region and URLs. Safe to rerun: what already
# matches is left alone, a value that differs is set again, and an existing reviewer is kept.
set -euo pipefail

usage="usage: $0 [--aws-account AWS_ACCOUNT_ID] [--ecr-repository-url URL] [--prod-reviewer LOGIN] [--apply | --teardown]"

die() { echo "error: $*" >&2; exit 1; }

# shellcheck source=infra/bootstrap/settings.sh
. "$(dirname "$0")/settings.sh"
load_settings
require_settings RENTSYNC_GITHUB_REPO RENTSYNC_AWS_REGION RENTSYNC_DOMAIN
repo="$RENTSYNC_GITHUB_REPO" region="$RENTSYNC_AWS_REGION" domain="$RENTSYNC_DOMAIN"

mode="plan" aws_account_id="${RENTSYNC_AWS_ACCOUNT_ID:-}" ecr_url="" reviewer=""
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-account) aws_account_id="${2:-}"; shift ;;
    --ecr-repository-url) ecr_url="${2:-}"; shift ;;
    --prod-reviewer) reviewer="${2:-}"; shift ;;
    --apply) mode="apply" ;;
    --teardown) mode="teardown" ;;
    *) die "$usage" ;;
  esac
  shift
done
[[ "$aws_account_id" =~ ^[0-9]{12}$ ]] || die "the AWS account ID (settings or --aws-account) must be 12 digits"
if [ -n "$ecr_url" ] && ! [[ "$ecr_url" =~ ^$aws_account_id\.dkr\.ecr\.$region\.amazonaws\.com/[a-z0-9._/-]+$ ]]; then
  die "--ecr-repository-url must be an ECR repository URL in AWS account $aws_account_id ($region)"
fi
role() { echo "arn:aws:iam::$aws_account_id:role/rentsync-$1"; }

# On Windows, `bash` typed in PowerShell is WSL, which cannot see the Windows gh install.
command -v gh > /dev/null || die "gh not found on this bash's PATH. Install it (macOS: brew install gh). On Windows, run this from Git Bash,
or from PowerShell as: & \"C:\\Program Files\\Git\\bin\\bash.exe\" infra/bootstrap/bootstrap-github.sh ..."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

api_get() { # var path jq: sets var to the jq result of a GET; returns 1 on HTTP 404
  local out
  if out="$(gh api "$2" --jq "$3" 2> "$tmp/err")"; then printf -v "$1" '%s' "$out"; return 0; fi
  if grep -q "HTTP 404" "$tmp/err"; then return 1; fi
  die "gh api $2 failed: $(cat "$tmp/err")"
}

changes=0
step() { # description, then the command that makes the change under --apply
  changes=$((changes + 1))
  echo "+ $1"; shift
  if [ "$mode" = "apply" ]; then "$@" > /dev/null; fi
}

ensure_var() { # name value [environment]
  local name="$1" value="$2" env="${3:-}" current
  local path="repos/$repo/actions/variables/$name" where="repository" scope=()
  if [ -n "$env" ]; then
    path="repos/$repo/environments/$env/variables/$name" where="$env Environment" scope=(--env "$env")
  fi
  if ! api_get current "$path" .value; then
    step "set $where variable $name = $value" gh variable set "$name" --repo "$repo" --body "$value" "${scope[@]}"
  elif [ "$current" != "$value" ]; then
    step "update $where variable $name: $current -> $value" gh variable set "$name" --repo "$repo" --body "$value" "${scope[@]}"
  else
    echo "  $where variable $name is set"
  fi
}

# Branches restricted to an allow-list (custom policies), plus required reviewers. Existing
# reviewers are carried into every update, so a rerun never removes one.
ensure_environment() { # name [reviewer user ID]
  local env="$1" want="${2:-}" state="" custom="false" reviewers="" r items=() body
  if api_get state "repos/$repo/environments/$env" \
       '"\(.deployment_branch_policy.custom_branch_policies // false) \([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[] | "\(.type):\(.reviewer.id)"] | join(","))"'; then
    custom="${state%% *}" reviewers="${state#* }"
  fi
  if [ -n "$want" ] && [[ ",$reviewers," != *",User:$want,"* ]]; then
    reviewers="${reviewers:+$reviewers,}User:$want"
  elif [ -n "$state" ] && [ "$custom" = "true" ]; then
    echo "  Environment $env exists with deployment branches restricted"
    return
  fi
  for r in ${reviewers//,/ }; do items+=("{\"type\":\"${r%%:*}\",\"id\":${r#*:}}"); done
  body="{\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}"
  if [ ${#items[@]} -gt 0 ]; then body+=",\"reviewers\":[$(IFS=,; echo "${items[*]}")]"; fi
  echo "$body}" > "$tmp/$env.json"
  local what="update"; [ -n "$state" ] || what="create"
  step "$what Environment $env (deployment branches restricted${reviewers:+; reviewers $reviewers})" \
    gh api -X PUT "repos/$repo/environments/$env" --input "$tmp/$env.json"
}

# The release roles trust the Environments by name, so `main` must be the only branch allowed.
ensure_main_only() { # environment
  local env="$1" policies="" line found=0
  api_get policies "repos/$repo/environments/$env/deployment-branch-policies" \
    '.branch_policies[] | "\(.id) \(.type // "branch") \(.name)"' || true
  while read -r line; do
    [ -n "$line" ] || continue
    if [ "${line#* }" = "branch main" ]; then found=1; continue; fi
    step "remove $env deployment branch policy '${line#* }'" \
      gh api -X DELETE "repos/$repo/environments/$env/deployment-branch-policies/${line%% *}"
  done <<< "$policies"
  if [ "$found" = 1 ]; then
    echo "  Environment $env allows branch main only"
  else
    step "allow branch main in Environment $env" \
      gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" -f name=main -f type=branch
  fi
}

# --- Teardown (constitution: Reversible bootstrap) -----------------------------------------
# Deletes the variables and Environments this script sets; deleting an Environment also deletes
# its variables, branch policies and reviewers. Secret scanning and push protection stay on.
if [ "$mode" = "teardown" ]; then
  todo=()
  plan() { echo "- $1"; shift; todo+=("$(printf '%q ' "$@")"); }
  echo "Teardown plan for $repo:"
  for name in AWS_BUILD_ROLE_ARN AWS_ROLE_ARN AWS_REGION ECR_REPOSITORY_URL; do
    found=""
    api_get found "repos/$repo/actions/variables/$name" .name || continue
    plan "delete repository variable $name" gh variable delete "$name" --repo "$repo"
  done
  for env in dev-staging prod-us; do
    found=""
    api_get found "repos/$repo/environments/$env" .name || continue
    plan "delete Environment $env, with its variables, branch policies and reviewers" \
      gh api -X DELETE "repos/$repo/environments/$env"
  done
  echo "  kept: secret scanning and push protection, which protect the repository either way."
  if [ ${#todo[@]} -eq 0 ]; then
    echo "Nothing to delete."
    exit 0
  fi
  confirm_teardown "the bootstrap's GitHub variables and Environments" || exit 1
  for cmd in "${todo[@]}"; do eval "$cmd" > /dev/null; done
  echo "Deleted. ${#todo[@]} GitHub changes made."
  exit 0
fi

echo "Plan ($mode) for $repo:"
reviewer_id=""
if [ -n "$reviewer" ]; then
  api_get reviewer_id "users/$reviewer" .id || die "no GitHub user named '$reviewer'"
fi

ensure_var AWS_BUILD_ROLE_ARN "$(role github-build)"
ensure_var AWS_ROLE_ARN "$(role github-actions)"
ensure_var AWS_REGION "$region"
[ -z "$ecr_url" ] || ensure_var ECR_REPOSITORY_URL "$ecr_url"

ensure_environment dev-staging
ensure_main_only dev-staging
ensure_var SITE_URL "https://pms-staging.$domain" dev-staging

ensure_environment prod-us "$reviewer_id"
ensure_main_only prod-us
ensure_var SITE_URL "https://pms.$domain" prod-us
ensure_var AWS_ROLE_ARN "$(role github-actions-prod)" prod-us

security=""
api_get security "repos/$repo" \
  '"\(.security_and_analysis.secret_scanning.status) \(.security_and_analysis.secret_scanning_push_protection.status)"'
if [ "$security" = "enabled enabled" ]; then
  echo "  secret scanning and push protection are on"
else
  echo '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' \
    > "$tmp/security.json"
  step "turn on secret scanning and push protection" \
    gh api -X PATCH "repos/$repo" --input "$tmp/security.json"
fi

echo
if [ "$changes" = 0 ]; then
  echo "No changes: GitHub already matches."
elif [ "$mode" = "apply" ]; then
  echo "Made $changes changes."
else
  echo "$changes changes planned. Rerun with --apply to make them."
fi
[ -n "$ecr_url" ] || echo "ECR_REPOSITORY_URL not set: rerun with --ecr-repository-url after the first rentsync-shared-us apply."
