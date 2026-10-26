#!/usr/bin/env bash
# Runbook §Bootstrap step 1 (feature 002): the two OIDC providers and the four bootstrap roles,
# from the policy files in docs/deploy/iam/. Meant for AWS CloudShell, which runs as the console
# session, so no access key is ever created.
#
#   bootstrap-iam.sh             render, validate, and print the plan; changes nothing
#   bootstrap-iam.sh --apply     the same, then create or update what the plan lists
#   bootstrap-iam.sh --teardown  list what the bootstrap created, then delete it after a typed
#                                confirmation (constitution: Reversible bootstrap)
#
# Settings come from .bootstrap/settings.env (bootstrap-init.sh prints a block that writes the
# four this script needs). Filled-in copies go to $RENTSYNC_IAM_OUT (default
# <repo>/.bootstrap/iam, gitignored), so no deployment's values land in a tracked file. Safe to
# rerun: what exists is skipped or updated.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="${RENTSYNC_IAM_SRC:-$repo/docs/deploy/iam}"
out="${RENTSYNC_IAM_OUT:-$repo/.bootstrap/iam}"
# Each <stem>-policy.json and <stem>-trust.json pair becomes policy and role rentsync-<stem>.
stems="hcp-terraform github-build github-actions github-actions-prod"

die() { echo "error: $*" >&2; exit 1; }

mode="plan"
case "${1:-}" in
  "") ;;
  --apply) mode="apply" ;;
  --teardown) mode="teardown" ;;
  *) die "usage: $0 [--apply | --teardown]" ;;
esac

# shellcheck source=infra/bootstrap/settings.sh
. "$repo/infra/bootstrap/settings.sh"
load_settings
require_settings RENTSYNC_AWS_ACCOUNT_ID RENTSYNC_AWS_REGION RENTSYNC_HCP_ORG RENTSYNC_GITHUB_SUBJECT
region="$RENTSYNC_AWS_REGION"

aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
[[ "$aws_account_id" =~ ^[0-9]{12}$ ]] || die "AWS account ID must be 12 digits, got '$aws_account_id'"
[ "$aws_account_id" = "$RENTSYNC_AWS_ACCOUNT_ID" ] \
  || die "signed in to AWS account $aws_account_id, but the settings say $RENTSYNC_AWS_ACCOUNT_ID"

# --- Teardown (constitution: Reversible bootstrap) -----------------------------------------
# Deletes only what the bootstrap creates, by exact name: Terraform makes its own rentsync-*
# roles, which are left alone. A provider without the rentsync:bootstrap tag was adopted, not
# created, so it is reported instead.
if [ "$mode" = "teardown" ]; then
  gone() { # true when the read-only aws call fails with NoSuchEntity
    local err
    if err="$(aws "$@" 2>&1 > /dev/null)"; then return 1; fi
    grep -q NoSuchEntity <<< "$err" && return 0
    die "aws $1 $2 failed: $err"
  }
  todo=()
  plan() { echo "- $1"; shift; todo+=("$(printf '%q ' "$@")"); }

  # Infrastructure is destroyed first (runbook §Teardown); the roles are what manage it.
  live="$(aws ec2 describe-instances --region "$region" --filters Name=tag-key,Values=DeploymentId \
    Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  live="$live $(aws ec2 describe-volumes --region "$region" --filters Name=tag-key,Values=DeploymentId \
    --query 'Volumes[].VolumeId' --output text)"
  if [ -n "${live// /}" ]; then
    die "infrastructure still exists in $region:$live. Destroy it first (runbook §Teardown); nothing was deleted"
  fi

  echo "Teardown plan for AWS account $aws_account_id:"
  for stem in $stems; do
    name="rentsync-$stem"
    gone iam get-role --role-name "$name" && continue
    for arn in $(aws iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyArn' --output text); do
      plan "detach $arn from role $name" aws iam detach-role-policy --role-name "$name" --policy-arn "$arn"
    done
    for inline in $(aws iam list-role-policies --role-name "$name" --query 'PolicyNames' --output text); do
      plan "delete inline policy $inline of role $name" aws iam delete-role-policy --role-name "$name" --policy-name "$inline"
    done
    plan "delete role $name" aws iam delete-role --role-name "$name"
  done
  for stem in $stems; do
    name="rentsync-$stem"
    policy_arn="arn:aws:iam::$aws_account_id:policy/$name"
    gone iam get-policy --policy-arn "$policy_arn" && continue
    users="$(aws iam list-entities-for-policy --policy-arn "$policy_arn" \
      --query '[PolicyRoles[].RoleName, PolicyUsers[].UserName, PolicyGroups[].GroupName][]' --output text)"
    for user in $users; do
      [ "$user" = "$name" ] || die "policy $name is also attached to $user; detach it first. Nothing was deleted"
    done
    for version in $(aws iam list-policy-versions --policy-arn "$policy_arn" \
                       --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
      plan "delete version $version of policy $name" aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version"
    done
    plan "delete policy $name" aws iam delete-policy --policy-arn "$policy_arn"
  done
  providers="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text)"
  adopted=()
  for host in app.terraform.io token.actions.githubusercontent.com; do
    arn="arn:aws:iam::$aws_account_id:oidc-provider/$host"
    grep -qxF "$arn" <<< "$(tr '\t' '\n' <<< "$providers")" || continue
    if [ "$(aws iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" \
            --query "Tags[?Key=='rentsync:bootstrap'].Value" --output text)" = "true" ]; then
      plan "delete OIDC provider $host" aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn"
    else
      adopted+=("$arn")
    fi
  done
  if [ "$(aws ce list-cost-allocation-tags --region "$region" --tag-keys DeploymentId \
          --query 'CostAllocationTags[0].Status' --output text)" = "Active" ]; then
    plan "deactivate the DeploymentId cost allocation tag" aws ce update-cost-allocation-tags-status \
      --region "$region" --cost-allocation-tags-status TagKey=DeploymentId,Status=Inactive
  fi

  for arn in "${adopted[@]}"; do
    echo "  kept: OIDC provider ${arn##*/}. The bootstrap adopted it rather than creating it. If nothing"
    echo "    else in this AWS account uses it, delete it yourself:"
    echo "    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $arn"
  done
  echo "  kept: .bootstrap/settings.env, which the next bootstrap reads."
  if [ ${#todo[@]} -eq 0 ]; then
    echo "Nothing to delete."
    exit 0
  fi
  confirm_teardown "the bootstrap's AWS roles, policies and providers" || exit 1
  for cmd in "${todo[@]}"; do eval "$cmd" > /dev/null; done
  echo "Deleted. ${#todo[@]} AWS changes made."
  exit 0
fi

# --- Render ------------------------------------------------------------------------------
mkdir -p "$out"
for f in "$src"/*.json; do
  sed -e "s/<aws-account-id>/$aws_account_id/g" -e "s/<aws-region>/$region/g" \
    -e "s/<hcp-organization>/$RENTSYNC_HCP_ORG/g" -e "s|<github-subject>|$RENTSYNC_GITHUB_SUBJECT|g" \
    "$f" > "$out/$(basename "$f")"
done
if grep -l '<[A-Za-z_-]*>' "$out"/*.json >&2; then
  die "placeholders remain in the files above"
fi
echo "Rendered $(find "$out" -name '*.json' | wc -l | tr -d ' ') files for AWS account $aws_account_id into $out"

# --- Validate (IAM Access Analyzer, the console editor's "Policy validation") -------------
blocked=0
validate() { # file, then the validate-policy type arguments
  local file="$1" findings
  shift
  findings="$(aws accessanalyzer validate-policy --region "$region" "$@" \
    --policy-document "file://$file" \
    --query 'findings[].[findingType,issueCode,findingDetails]' --output text)"
  [ -z "$findings" ] && return 0
  echo "$(basename "$file"):"
  while IFS= read -r line; do echo "  $line"; done <<< "$findings"
  if grep -qE '^(ERROR|SECURITY_WARNING)' <<< "$findings"; then blocked=1; fi
}
for stem in $stems; do
  validate "$out/$stem-policy.json" --policy-type IDENTITY_POLICY
  validate "$out/$stem-trust.json" --policy-type RESOURCE_POLICY \
    --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument
done
[ "$blocked" = 0 ] || die "Access Analyzer reported an ERROR or SECURITY_WARNING; nothing was changed"
echo "Access Analyzer: no errors or security warnings"

# --- Plan / apply ------------------------------------------------------------------------
changes=0
step() { # prints a change, and makes it under --apply
  changes=$((changes + 1))
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [ "$mode" = "apply" ]; then "$@" > /dev/null; fi
}
exists() { # true if the read-only aws call succeeds; false only for NoSuchEntity
  local err
  if err="$(aws "$@" 2>&1 > /dev/null)"; then return 0; fi
  if grep -q NoSuchEntity <<< "$err"; then return 1; fi
  die "aws $1 $2 failed: $err"
}

echo
echo "Plan ($mode):"
providers="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text)"
for pair in app.terraform.io=aws.workload.identity token.actions.githubusercontent.com=sts.amazonaws.com; do
  host="${pair%%=*}" audience="${pair#*=}"
  arn="arn:aws:iam::$aws_account_id:oidc-provider/$host"
  if ! grep -qxF "$arn" <<< "$(tr '\t' '\n' <<< "$providers")"; then
    # Tagged, so --teardown can tell a provider it created from one it adopted.
    step aws iam create-open-id-connect-provider --url "https://$host" --client-id-list "$audience" \
      --tags Key=rentsync:bootstrap,Value=true
  elif ! grep -qxF "$audience" <<< "$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" \
         --query ClientIDList --output text | tr '\t' '\n')"; then
    step aws iam add-client-id-to-open-id-connect-provider --open-id-connect-provider-arn "$arn" \
      --client-id "$audience"
  else
    echo "  provider $host exists with audience $audience"
  fi
done

for stem in $stems; do
  name="rentsync-$stem"
  policy_arn="arn:aws:iam::$aws_account_id:policy/$name"
  if exists iam get-policy --policy-arn "$policy_arn"; then
    # Not changed automatically: a policy keeps at most five versions.
    echo "  policy $name exists; not changed. If it differs from $out/$stem-policy.json, run:"
    printf '    aws iam create-policy-version --policy-arn %q --set-as-default --policy-document %q\n' \
      "$policy_arn" "file://$out/$stem-policy.json"
  else
    step aws iam create-policy --policy-name "$name" --policy-document "file://$out/$stem-policy.json"
  fi
  if exists iam get-role --role-name "$name"; then
    step aws iam update-assume-role-policy --role-name "$name" \
      --policy-document "file://$out/$stem-trust.json"
  else
    step aws iam create-role --role-name "$name" \
      --assume-role-policy-document "file://$out/$stem-trust.json"
  fi
  step aws iam attach-role-policy --role-name "$name" --policy-arn "$policy_arn"
done

echo
if [ "$mode" = "plan" ]; then
  echo "$changes change(s) planned. Nothing was changed; rerun with --apply to make them."
else
  echo "$changes change(s) applied."
fi

echo
echo "Role ARNs. Nothing to copy: bootstrap-hcp.rb and bootstrap-github.sh build them from"
echo "the settings and set them where shown."
echo "  arn:aws:iam::$aws_account_id:role/rentsync-hcp-terraform        -> HCP variable set TFC_AWS_RUN_ROLE_ARN"
echo "  arn:aws:iam::$aws_account_id:role/rentsync-github-build         -> GitHub repository variable AWS_BUILD_ROLE_ARN"
echo "  arn:aws:iam::$aws_account_id:role/rentsync-github-actions       -> GitHub repository variable AWS_ROLE_ARN"
echo "  arn:aws:iam::$aws_account_id:role/rentsync-github-actions-prod  -> GitHub prod-us Environment variable AWS_ROLE_ARN"
