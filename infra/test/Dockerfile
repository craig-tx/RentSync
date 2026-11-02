# The Linux environment the infra shell tests run in on a developer machine (Windows or macOS),
# so they behave the same as in CI: GNU tools, util-linux script(1) and flock, real file modes,
# and jq for the gh stub. Built and used by run.sh; nothing is published.
FROM debian:13-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
