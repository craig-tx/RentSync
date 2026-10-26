#!/usr/bin/env bash
# Test for rentsync-swap (feature 002 research R4). Linux only, as root (swapon), so it runs in
# CI rather than in infra/test/run.sh:
#   sudo bash infra/host/test/swap_test.sh
# Proves: a bad size is refused; the first run creates a 0600 swap file, turns it on and adds
# one fstab line; a rerun keeps the same file and adds nothing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
swap="$here/../bin/rentsync-swap"
work="$(mktemp -d)"
file="$work/swapfile"
export RENTSYNC_SWAPFILE="$file" RENTSYNC_FSTAB="$work/fstab"
cleanup() { swapoff "$file" 2> /dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
active() { swapon --show=NAME --noheadings | grep -qxF "$file"; }

for bad in "" 0 -5 1.5 abc; do
  if bash "$swap" "$bad" > /dev/null 2>&1; then fail "accepted size '$bad'"; fi
done
[ ! -e "$file" ] || fail "a refused size still created a file"

bash "$swap" 16 > /dev/null || fail "first run failed"
[ "$(stat -c %s "$file")" -eq $((16 * 1024 * 1024)) ] || fail "swap file is not 16 MiB"
[ "$(stat -c %a "$file")" = 600 ] || fail "swap file is not mode 600"
active || fail "swap file is not active"
[ "$(grep -c "^$file none swap " "$RENTSYNC_FSTAB")" -eq 1 ] || fail "fstab lacks exactly one swap line"

inode="$(stat -c %i "$file")"
bash "$swap" 16 > /dev/null || fail "rerun failed"
[ "$(stat -c %i "$file")" = "$inode" ] || fail "a rerun recreated the swap file"
active || fail "a rerun turned swap off"
[ "$(grep -c "^$file none swap " "$RENTSYNC_FSTAB")" -eq 1 ] || fail "a rerun added a second fstab line"

echo "PASS: rentsync-swap"
