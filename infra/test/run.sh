#!/usr/bin/env bash
# Runs the infra shell tests in a Linux container, the same way on Windows (Git Bash) and macOS.
# The tests exercise scripts that run on Linux (the hosts, CloudShell) and rely on GNU tools,
# script(1), flock and POSIX file modes, so they are not run natively on a developer machine.
#
#   bash infra/test/run.sh            # every test below
#   bash infra/test/run.sh render_env # only the tests whose path contains "render_env"
#
# Not included: boot_volume_test.sh and rehearse/ need root and loop devices (CI and a Linux host
# only), and bootstrap_hcp_test.rb is plain Ruby that runs natively anywhere.
set -euo pipefail

tests=(
  infra/host/test/render_env_test.sh
  infra/host/test/deploy_test.sh
  infra/bootstrap/test/bootstrap_init_test.sh
  infra/bootstrap/test/bootstrap_iam_test.sh
  infra/bootstrap/test/bootstrap_github_test.sh
)

root="$(cd "$(dirname "$0")/../.." && pwd)"
selected=()
for t in "${tests[@]}"; do [[ $t == *"${1:-}"* ]] && selected+=("$t"); done
[ "${#selected[@]}" -gt 0 ] || { echo "no test matches '$1'" >&2; exit 2; }

if [ "${RENTSYNC_IN_TEST_CONTAINER:-}" != 1 ]; then
  command -v docker > /dev/null || { echo "Docker is required: https://docs.docker.com/get-docker/" >&2; exit 2; }
  mount="$root"
  command -v cygpath > /dev/null && mount="$(cygpath -w "$mount")" # Git Bash on Windows
  docker build -q -t rentsync-infra-test "$root/infra/test" > /dev/null
  # Read-only, so a test that writes into the checkout fails here as it would on any machine.
  # MSYS_NO_PATHCONV stops Git Bash rewriting /src into a Windows path.
  MSYS_NO_PATHCONV=1 exec docker run --rm -v "$mount:/src:ro" -w /src \
    -e RENTSYNC_IN_TEST_CONTAINER=1 rentsync-infra-test bash infra/test/run.sh "${1:-}"
fi

failed=0
for t in "${selected[@]}"; do
  if out="$(bash "$t" 2>&1)"; then
    echo "pass  $t"
  else
    echo "FAIL  $t"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'; failed=1
  fi
done
exit "$failed"
