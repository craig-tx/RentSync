#!/usr/bin/env bash
# Runbook §Operator CLI access: the role rentsync-operator, which the operator's AWS CLI assumes
# for checks on the hosts (SSM sessions and commands, reading each deployment's admin token)
# without any access key. Meant for AWS CloudShell, like bootstrap-iam.sh.
#
#   bootstrap-operator.sh                    render, validate, and print the plan; changes nothing
#   bootstrap-operator.sh --apply            the same, then create or update what the plan lists
#   bootstrap-operator.sh --teardown         list the role and policy, then delete them after a
#                                            typed confirmation (constitution: Reversible bootstrap)
#   ... --principal <arn>                    trust this IAM user or role ARN instead of the
#                                            identity CloudShell is signed in as
#
# The role trusts exactly one identity: by default the one running this script, which is the
# identity `aws login` signs in as on the operator's machine. The root user cannot assume roles,
# so it is refused. The plan and --apply end by printing the ~/.aws/config profiles to add.
#
# Settings come from .bootstrap/settings.env. The filled-in documents go to
# $RENTSYNC_IAM_OUT/operator (default <repo>/.bootstrap/iam/operator, gitignored). Safe to rerun.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="${RENTSYNC_IAM_SRC:-$repo/docs/deploy/iam}/operator"
out="${RENTSYNC_IAM_OUT:-$repo/.bootstrap/iam}/operator"
name="rentsync-operator"
managed_policy="arn:aws:iam::aws:policy/ReadOnlyAccess"

die() { echo "error: $*" >&2; exit 1; }

mode="plan"
principal=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) mode="apply" ;;
    --teardown) mode="teardown" ;;
    --principal) [ $# -ge 2 ] || die "--principal needs an ARN"; principal="$2"; shift ;;
    *) die "usage: $0 [--apply | --teardown] [--principal <arn>]" ;;
  esac
  shift
done

# shellcheck source=infra/bootstrap/settings.sh
. "$repo/infra/bootstrap/settings.sh"
load_settings
require_settings RENTSYNC_AWS_ACCOUNT_ID RENTSYNC_AWS_REGION
region="$RENTSYNC_AWS_REGION"

read -r aws_account_id caller < <(aws sts get-caller-identity --query '[Account,Arn]' --output text)
[[ "$aws_account_id" =~ ^[0-9]{12}$ ]] || die "AWS account ID must be 12 digits, got '$aws_account_id'"
[ "$aws_account_id" = "$RENTSYNC_AWS_ACCOUNT_ID" ] \
  || die "signed in to AWS account $aws_account_id, but the settings say $RENTSYNC_AWS_ACCOUNT_ID"
policy_arn="arn:aws:iam::$aws_account_id:policy/$name"

gone() { # true when the read-only aws call fails with NoSuchEntity
  local err
  if err="$(aws "$@" 2>&1 > /dev/null)"; then return 1; fi
  grep -q NoSuchEntity <<< "$err" && return 0
  die "aws $1 $2 failed: $err"
}

# --- Teardown (constitution: Reversible bootstrap) -----------------------------------------
if [ "$mode" = "teardown" ]; then
  todo=()
  plan() { echo "- $1"; shift; todo+=("$(printf '%q ' "$@")"); }
  echo "Teardown plan for AWS account $aws_account_id:"
  if ! gone iam get-role --role-name "$name"; then
    for arn in $(aws iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyArn' --output text); do
      plan "detach $arn from role $name" aws iam detach-role-policy --role-name "$name" --policy-arn "$arn"
    done
    for inline in $(aws iam list-role-policies --role-name "$name" --query 'PolicyNames' --output text); do
      plan "delete inline policy $inline of role $name" aws iam delete-role-policy --role-name "$name" --policy-name "$inline"
    done
    plan "delete role $name" aws iam delete-role --role-name "$name"
  fi
  if ! gone iam get-policy --policy-arn "$policy_arn"; then
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
  fi
  echo "  kept: the rentsync and rentsync-login profiles in ~/.aws/config on your machine; remove them yourself."
  if [ ${#todo[@]} -eq 0 ]; then
    echo "Nothing to delete."
    exit 0
  fi
  confirm_teardown "the operator role and its policy" || exit 1
  for cmd in "${todo[@]}"; do eval "$cmd" > /dev/null; done
  echo "Deleted. ${#todo[@]} AWS changes made."
  exit 0
fi

# --- The identity the role trusts ----------------------------------------------------------
# An assumed-role ARN (arn:aws:sts::<id>:assumed-role/<role>/<session>) omits the role's path,
# which IAM Identity Center roles have, so the role's real ARN is read from IAM.
[ -n "$principal" ] || principal="$caller"
case "$principal" in
  "arn:aws:iam::$aws_account_id:root")
    die "you are signed in as the root user, which cannot assume a role. Sign in to the console as an
  IAM user with console access (and no access keys), rerun this from CloudShell, and use that user
  for 'aws login' too. Or pass --principal with that user's ARN." ;;
  "arn:aws:sts::$aws_account_id:assumed-role/"*)
    role="${principal#*:assumed-role/}"
    role="${role%%/*}"
    principal="$(aws iam get-role --role-name "$role" --query Role.Arn --output text)" \
      || die "could not read role $role to find its ARN; pass --principal" ;;
  "arn:aws:iam::$aws_account_id:user/"* | "arn:aws:iam::$aws_account_id:role/"*) ;;
  *) die "cannot trust '$principal': expected an IAM user or role in AWS account $aws_account_id" ;;
esac
[ "$principal" != "arn:aws:iam::$aws_account_id:role/$name" ] || die "the role cannot trust itself; pass --principal"

# --- Render ------------------------------------------------------------------------------
mkdir -p "$out"
for f in "$src"/*.json; do
  sed -e "s/<aws-account-id>/$aws_account_id/g" -e "s/<aws-region>/$region/g" \
    -e "s|<operator-principal>|$principal|g" "$f" > "$out/$(basename "$f")"
done
if grep -l '<[A-Za-z_-]*>' "$out"/*.json >&2; then
  die "placeholders remain in the files above"
fi
echo "Rendered the operator role's documents for AWS account $aws_account_id into $out"
echo "The role will trust: $principal"

# --- Validate (IAM Access Analyzer) --------------------------------------------------------
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
validate "$out/policy.json" --policy-type IDENTITY_POLICY
validate "$out/trust.json" --policy-type RESOURCE_POLICY \
  --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument
[ "$blocked" = 0 ] || die "Access Analyzer reported an ERROR or SECURITY_WARNING; nothing was changed"
echo "Access Analyzer: no errors or security warnings"

# --- Plan / apply ------------------------------------------------------------------------
changes=0
step() { # prints a change, and makes it under --apply
  changes=$((changes + 1))
  printf '+'; printf ' %q' "$@"; printf '\n'
  if [ "$mode" = "apply" ]; then "$@" > /dev/null; fi
}

echo
echo "Plan ($mode):"
if gone iam get-policy --policy-arn "$policy_arn"; then
  step aws iam create-policy --policy-name "$name" --policy-document "file://$out/policy.json" \
    --tags Key=rentsync:bootstrap,Value=true
else
  # Not changed automatically: a policy keeps at most five versions.
  echo "  policy $name exists; not changed. If it differs from $out/policy.json, run:"
  printf '    aws iam create-policy-version --policy-arn %q --set-as-default --policy-document %q\n' \
    "$policy_arn" "file://$out/policy.json"
fi
if gone iam get-role --role-name "$name"; then
  # One hour: the profile asks for a new session when it expires.
  step aws iam create-role --role-name "$name" --max-session-duration 3600 \
    --description "RentSync operator checks from the AWS CLI (runbook: Operator CLI access)" \
    --assume-role-policy-document "file://$out/trust.json" --tags Key=rentsync:bootstrap,Value=true
else
  step aws iam update-assume-role-policy --role-name "$name" --policy-document "file://$out/trust.json"
fi
step aws iam attach-role-policy --role-name "$name" --policy-arn "$policy_arn"
step aws iam attach-role-policy --role-name "$name" --policy-arn "$managed_policy"

echo
if [ "$mode" = "plan" ]; then
  echo "$changes change(s) planned. Nothing was changed; rerun with --apply to make them."
else
  echo "$changes change(s) applied."
fi

cat <<EOF

On your machine, add these profiles to ~/.aws/config (%USERPROFILE%\\.aws\\config on Windows).
The file is outside the repository, so the AWS account ID in it stays private:

[profile rentsync-login]
region = $region

[profile rentsync]
role_arn = arn:aws:iam::$aws_account_id:role/$name
source_profile = rentsync-login
role_session_name = operator
region = $region

Then sign in, and check that the CLI is the operator role in this AWS account:

  aws login --profile rentsync-login
  aws sts get-caller-identity --profile rentsync

Use --profile rentsync for every RentSync command. rentsync-login has your console identity's
full permissions, so use it only as the source profile.
EOF
