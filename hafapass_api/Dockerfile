# Shared settings for the build and runtime stages. The Ruby version appears
# only on this line and must match .ruby-version (checked by
# spec/services/render_deployment_contract_spec.rb).
FROM ruby:3.3.13-slim AS base

WORKDIR /app

ENV RAILS_ENV=production \
    BUNDLE_WITHOUT="development:test"

# Build stage: compilers and headers for native gems never reach the runtime
# image.
FROM base AS build

RUN apt-get update -qq && \
    apt-get install -y build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

COPY . .

# Cache compiled Ruby and YAML ahead of time, so boot and the pre-deploy
# migration don't build it as the unprivileged user.
RUN bundle exec bootsnap precompile --gemfile app/ lib/

# Runtime stage: only the shared libraries and tools the app uses at run time.
# tzdata is explicit because event times depend on the system zoneinfo.
FROM base

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends libpq5 curl ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# Run as an unprivileged user. Application code stays root-owned and
# read-only; only the directories Rails, Puma and bootsnap write to are
# owned by rails.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p tmp/pids tmp/cache log storage && \
    chown -R rails:rails tmp log storage
USER 1000:1000

EXPOSE 10000

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
