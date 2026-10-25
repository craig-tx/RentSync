#!/usr/bin/env bash
# Runbook §Bootstrap steps 1–2 (feature 002): the two OIDC providers and the four bootstrap
# roles, from the policy files in docs/deploy/iam/. Meant for AWS CloudShell, which runs as the
# console session, so no access key is ever created.
#
#   bootstrap-iam.sh                        render, validate, and print the plan; changes nothing
#   bootstrap-iam.sh --apply                the same, then create or update what the plan lists
#   bootstrap-iam.sh --render-only ACCOUNT  only write the filled-in copies; no AWS calls
#
# Filled-in copies go to $RENTSYNC_IAM_OUT (default <repo>/.bootstrap/iam, gitignored), so the
# account ID never lands in a tracked file. Safe to rerun: what exists is skipped or updated.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="${RENTSYNC_IAM_SRC:-$repo/docs/deploy/iam}"
out="${RENTSYNC_IAM_OUT:-$repo/.bootstrap/iam}"
region="us-east-1"
# Each <stem>-policy.json and <stem>-trust.json pair becomes policy and role rentsync-<stem>.
stems="hcp-terraform github-build github-actions github-actions-prod"

die() { echo "error: $*" >&2; exit 1; }

mode="plan"
account=""
case "${1:-}" in
  "") ;;
  --apply) mode="apply" ;;
  --render-only) mode="render"; account="${2:-}" ;;
  *) die "usage: $0 [--apply | --render-only ACCOUNT]" ;;
esac

if [ "$mode" != "render" ]; then
  account="$(aws sts get-caller-identity --query Account --output text)"
fi
[[ "$account" =~ ^[0-9]{12}$ ]] || die "account ID must be 12 digits, got '$account'"

# --- Render ------------------------------------------------------------------------------
mkdir -p "$out"
for f in "$src"/*.json; do
  sed "s/<account>/$account/g" "$f" > "$out/$(basename "$f")"
done
if grep -l '<[A-Za-z_-]*>' "$out"/*.json >&2; then
  die "placeholders remain in the files above"
fi
echo "Rendered $(find "$out" -name '*.json' | wc -l | tr -d ' ') files for account $account into $out"
[ "$mode" = "render" ] && exit 0

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
  if echo "$findings" | grep -qE '^(ERROR|SECURITY_WARNING)'; then blocked=1; fi
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
  if echo "$err" | grep -q NoSuchEntity; then return 1; fi
  die "aws $1 $2 failed: $err"
}

echo
echo "Plan ($mode):"
providers="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text)"
for pair in app.terraform.io=aws.workload.identity token.actions.githubusercontent.com=sts.amazonaws.com; do
  host="${pair%%=*}" audience="${pair#*=}"
  arn="arn:aws:iam::$account:oidc-provider/$host"
  if ! echo "$providers" | tr '\t' '\n' | grep -qxF "$arn"; then
    step aws iam create-open-id-connect-provider --url "https://$host" --client-id-list "$audience"
  elif ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" \
         --query ClientIDList --output text | tr '\t' '\n' | grep -qxF "$audience"; then
    step aws iam add-client-id-to-open-id-connect-provider --open-id-connect-provider-arn "$arn" \
      --client-id "$audience"
  else
    echo "  provider $host exists with audience $audience"
  fi
done

for stem in $stems; do
  name="rentsync-$stem"
  policy_arn="arn:aws:iam::$account:policy/$name"
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
echo "Role ARNs (runbook §Bootstrap, values table):"
echo "  rentsync-hcp-terraform        arn:aws:iam::$account:role/rentsync-hcp-terraform        -> HCP variable set TFC_AWS_RUN_ROLE_ARN"
echo "  rentsync-github-build         arn:aws:iam::$account:role/rentsync-github-build         -> GitHub repository variable AWS_BUILD_ROLE_ARN"
echo "  rentsync-github-actions       arn:aws:iam::$account:role/rentsync-github-actions       -> GitHub repository variable AWS_ROLE_ARN"
echo "  rentsync-github-actions-prod  arn:aws:iam::$account:role/rentsync-github-actions-prod  -> GitHub prod-us Environment variable AWS_ROLE_ARN"
