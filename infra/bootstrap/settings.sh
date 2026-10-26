# Sourced by the bootstrap shell scripts. Loads the deployment settings that bootstrap-init.sh
# writes, by default to .bootstrap/settings.env (gitignored). Every line must be KEY='value' with
# a RENTSYNC_ key, so loading the file assigns variables and never runs code.
# shellcheck shell=bash

settings_file="${RENTSYNC_SETTINGS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.bootstrap/settings.env}"

load_settings() {
  if [ ! -f "$settings_file" ]; then
    echo "error: no settings at $settings_file; run infra/bootstrap/bootstrap-init.sh first" >&2
    exit 1
  fi
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "" | "#"*) continue ;; esac
    if ! [[ "$line" =~ ^(RENTSYNC_[A-Z_]+)=\'([^\']*)\'$ ]]; then
      echo "error: $settings_file: not a RENTSYNC_KEY='value' line: $line" >&2
      exit 1
    fi
    printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
  done < "$settings_file"
}

# The teardown confirmation (constitution: Reversible bootstrap). Succeeds only when an operator
# at an interactive terminal answers a small sum correctly; anything else deletes nothing.
# RENTSYNC_TEARDOWN_NUMBERS="a b" fixes the numbers so tests can answer; the terminal check and
# the question still apply.
confirm_teardown() { # what is being deleted, for the warning
  local a b answer
  echo
  echo "WARNING: this permanently deletes $1, everything listed above. It cannot be undone."
  if [ ! -t 0 ]; then
    echo "No interactive terminal to confirm at, so nothing was deleted." >&2
    return 1
  fi
  read -r a b <<< "${RENTSYNC_TEARDOWN_NUMBERS:-$((RANDOM % 8 + 2)) $((RANDOM % 8 + 2))}"
  read -r -p "If you are sure, type the answer to $a + $b: " answer || answer=""
  if [ "${answer%$'\r'}" != "$((a + b))" ]; then
    echo "That is not $((a + b)), so nothing was deleted." >&2
    return 1
  fi
}

require_settings() { # setting names
  local key
  for key in "$@"; do
    if [ -z "${!key:-}" ]; then
      echo "error: $key is not set in $settings_file; rerun infra/bootstrap/bootstrap-init.sh" >&2
      exit 1
    fi
  done
}
