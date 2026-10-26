#!/usr/bin/env bash
# Runbook §Bootstrap step 1 (feature 002): the two OIDC providers and the four bootstrap roles,
# from the policy files in docs/deploy/iam/. Meant for AWS CloudShell, which runs as the console
# session, so no access key is ever created.
#
#   bootstrap-iam.sh          render, validate, and print the plan; changes nothing
#   bootstrap-iam.sh --apply  the same, then create or update what the plan lists
#
# Filled-in copies go to $RENTSYNC_IAM_OUT (default <repo>/.bootstrap/iam, gitignored), so the
# AWS account ID never lands in a tracked file. Safe to rerun: what exists is skipped or updated.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="${RENTSYNC_IAM_SRC:-$repo/docs/deploy/iam}"
out="${RENTSYNC_IAM_OUT:-$repo/.bootstrap/iam}"
region="us-east-1"
# Each <stem>-policy.json and <stem>-trust.json pair becomes policy and role rentsync-<stem>.
stems="hcp-terraform github-build github-actions github-actions-prod"

die() { echo "error: $*" >&2; exit 1; }

mode="plan"
case "${1:-}" in
  "") ;;
  --apply) mode="apply" ;;
  *) die "usage: $0 [--apply]" ;;
esac

aws_account_id="$(aws sts get-caller-identity --query Account --output text)"
[[ "$aws_account_id" =~ ^[0-9]{12}$ ]] || die "AWS account ID must be 12 digits, got '$aws_account_id'"

# --- Render ------------------------------------------------------------------------------
mkdir -p "$out"
for f in "$src"/*.json; do
  sed "s/<aws-account-id>/$aws_account_id/g" "$f" > "$out/$(basename "$f")"
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
    step aws iam create-open-id-connect-provider --url "https://$host" --client-id-list "$audience"
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
echo "--aws-account $aws_account_id and set them where shown."
echo "  arn:aws:iam::$aws_account_id:role/rentsync-hcp-terraform        -> HCP variable set TFC_AWS_RUN_ROLE_ARN"
echo "  arn:aws:iam::$aws_account_id:role/rentsync-github-build         -> GitHub repository variable AWS_BUILD_ROLE_ARN"
echo "  arn:aws:iam::$aws_account_id:role/rentsync-github-actions       -> GitHub repository variable AWS_ROLE_ARN"
echo "  arn:aws:iam::$aws_account_id:role/rentsync-github-actions-prod  -> GitHub prod-us Environment variable AWS_ROLE_ARN"
