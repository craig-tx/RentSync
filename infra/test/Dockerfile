# The Linux environment the infra shell tests run in on a developer machine (Windows or macOS),
# so they behave the same as in CI: GNU tools, util-linux script(1) and flock, real file modes,
# and jq for the gh stub. Built and used by run.sh; nothing is published.
FROM debian:12-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
