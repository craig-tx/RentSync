# Two images from one file:
#   - production (the default target): runtime gems only, no compiler, runs as a non-root user.
#     The release workflow builds this.
#   - dev: every gem, including test and lint, for local Compose (`docker compose run mock_pms
#     bundle exec rspec`).

FROM ruby:4.0-slim AS base
WORKDIR /app
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends libpq5 curl \
 && rm -rf /var/lib/apt/lists/*
ENV BUNDLE_FROZEN=true \
    RACK_ENV=production

# Native gems (pg, bcrypt, puma) compile here; only their results reach production.
FROM base AS build
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./

FROM build AS dev
RUN bundle install --jobs 4
COPY . .
ARG GIT_SHA=dev
ENV SERVICE_VERSION=$GIT_SHA
EXPOSE 4001
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]

FROM build AS production-gems
ENV BUNDLE_WITHOUT=development:test
RUN bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

FROM base AS production
# UID 10001 owns /srv/data/receiver on the host (infra/host/bin/rentsync-boot).
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
ENV BUNDLE_WITHOUT=development:test
COPY --from=production-gems /usr/local/bundle /usr/local/bundle
COPY . .
ARG GIT_SHA=dev
ENV SERVICE_VERSION=$GIT_SHA
USER app
EXPOSE 4001
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
