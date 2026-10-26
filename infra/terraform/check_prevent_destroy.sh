#!/usr/bin/env bash
# Static checks that `terraform test` cannot express (feature 002 T038):
#   1. the host data volume keeps prevent_destroy (FR-034);
#   2. root volumes carry tags, because provider default_tags don't reach them (constitution VI);
#   3. no SecureString parameter sets `value`; secrets use value_wo only (research R11);
#   4. no host sets key_name: there is no SSH key pair (FR-009).
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
host="$root/modules/host/main.tf"
status=0
fail() { echo "FAIL: $*" >&2; status=1; }

# Prints one resource block, from its header to the closing brace at column 0.
block() { awk -v hdr="$2" 'index($0, hdr) == 1 { on = 1 } on { print } on && /^}/ { exit }' "$1"; }

grep -q 'prevent_destroy *= *true' <<< "$(block "$host" 'resource "aws_ebs_volume" "data"')" \
  || fail "aws_ebs_volume.data in modules/host/main.tf must keep prevent_destroy = true"

block "$host" 'resource "aws_instance" "this"' | awk '/root_block_device/ { on = 1 } on && /tags *= *\{/ { found = 1 } END { exit !found }' \
  || fail "aws_instance.this root_block_device must set tags"

while IFS= read -r file; do
  awk -v f="$file" '
    /^resource "aws_ssm_parameter"/ { in_res = 1; secure = 0; plain = 0; name = $3 }
    in_res && /type *= *"SecureString"/ { secure = 1 }
    in_res && /^[[:space:]]*value *=/ { plain = 1 }
    in_res && /^}/ { if (secure && plain) { print f ": " name " is a SecureString with value ="; bad = 1 } in_res = 0 }
    END { exit bad }
  ' "$file" || status=1
done < <(find "$root" -name '*.tf' -not -path '*/.terraform/*')

# No SSH key pair on any host (FR-009); key_name is computed, so terraform test cannot see it.
if grep -rn --include="*.tf" -E "^[[:space:]]*key_name[[:space:]]*=" "$root" --exclude-dir=.terraform; then
  fail "hosts must not set key_name (no SSH, FR-009)"
fi

[ "$status" -eq 0 ] && echo "ok: check_prevent_destroy"
exit "$status"
