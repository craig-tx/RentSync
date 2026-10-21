#!/usr/bin/env bash
# Driver for the host rehearsal (feature 002). Run from the repository root on a machine with
# Docker; no AWS access is needed:
#   bash infra/host/test/rehearse/rehearse.sh
# Builds two mock PMS images (versions A and B), starts a privileged docker:dind "host",
# loads the images into it, and runs run.sh there. Removes the dind container afterwards.
set -euo pipefail

A="$(git rev-parse HEAD)"
B="$(printf 'b%.0s' {1..40})"
name="rentsync-rehearsal"
repo_mount="$(pwd)"
command -v cygpath > /dev/null && repo_mount="$(cygpath -w "$repo_mount")" # Git Bash on Windows

cleanup() { docker rm -f "$name" > /dev/null 2>&1 || true; }
trap cleanup EXIT

for t in "$A" "$B"; do
  docker build -q --build-arg GIT_SHA="$t" -t "rehearsal:$t" mock_pms > /dev/null
done

cleanup
MSYS_NO_PATHCONV=1 docker run -d --privileged --name "$name" -v "$repo_mount:/repo:ro" docker:27.5.1-dind > /dev/null
for _ in $(seq 1 60); do docker exec "$name" docker info > /dev/null 2>&1 && break; sleep 1; done
docker save "rehearsal:$A" "rehearsal:$B" | docker exec -i "$name" docker load -q > /dev/null
docker exec "$name" apk add --no-cache -q bash > /dev/null
MSYS_NO_PATHCONV=1 docker exec "$name" bash /repo/infra/host/test/rehearse/run.sh "$A" "$B"
