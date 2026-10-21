FROM ruby:3.3-slim

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential libpq-dev curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without "" \
 && bundle install --jobs 4

COPY . .

ARG GIT_SHA=dev
ENV SERVICE_VERSION=$GIT_SHA \
    RACK_ENV=production

EXPOSE 4001

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
