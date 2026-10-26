#!/usr/bin/env bash
# Loop-device test for rentsync-boot (feature 002 research R6, T025). Linux only, as root (it
# needs loop devices and mkfs.xfs), so it runs in CI rather than in infra/test/run.sh:
#   sudo bash infra/host/test/boot_volume_test.sh
# Proves the data-safety rule: a blank volume is formatted and laid out, and a volume that
# already has a filesystem is never reformatted.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
boot="$here/../bin/rentsync-boot"
work="$(mktemp -d)"
img="$work/data.img"
mnt="$work/mnt"
etc="$work/etc"
loop=""

cleanup() {
  umount "$mnt" 2>/dev/null || true
  if [ -n "$loop" ]; then losetup -d "$loop" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

truncate -s 512M "$img" # sparse; XFS needs more than 300 MB
loop="$(losetup --find --show "$img")"
mkdir -p "$mnt" "$etc"
: > "$etc/host.env"

run_boot() {
  RENTSYNC_DATA_DEVICE="$loop" RENTSYNC_DATA_MOUNT="$mnt" RENTSYNC_ETC="$etc" \
    RENTSYNC_FSTAB="$etc/fstab" bash "$boot"
}

# 1. A blank volume is formatted, mounted and laid out.
run_boot
mountpoint -q "$mnt" || fail "volume not mounted after first boot"
for d in postgres caddy receiver openobserve openobserve-db; do
  [ -d "$mnt/$d" ] || fail "missing $d/ after first boot"
done
[ "$(stat -c %u:%g "$mnt/receiver")" = "10001:10001" ] || fail "receiver/ is not owned by the image's UID 10001"
grep -q "UUID=" "$etc/fstab" || fail "no UUID fstab entry"
grep -q "nofail" "$etc/fstab" || fail "fstab entry lacks nofail"

# 2. A volume with data is never reformatted.
echo "keep-me" > "$mnt/postgres/sentinel"
umount "$mnt"
run_boot
[ "$(cat "$mnt/postgres/sentinel" 2>/dev/null)" = "keep-me" ] || fail "sentinel lost: volume was reformatted"
[ "$(grep -c "UUID=" "$etc/fstab")" -eq 1 ] || fail "duplicate fstab entries after second boot"

echo "ok: boot_volume_test"
