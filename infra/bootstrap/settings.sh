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

require_settings() { # setting names
  local key
  for key in "$@"; do
    if [ -z "${!key:-}" ]; then
      echo "error: $key is not set in $settings_file; rerun infra/bootstrap/bootstrap-init.sh" >&2
      exit 1
    fi
  done
}
