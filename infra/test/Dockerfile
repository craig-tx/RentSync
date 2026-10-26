# The Linux environment the infra shell tests run in on a developer machine (Windows or macOS),
# so they behave the same as in CI: GNU tools, util-linux script(1) and flock, real file modes,
# and jq for the gh stub. Built and used by run.sh; nothing is published.
FROM debian:13-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
