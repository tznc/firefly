# Production image for Firefly: builds a `mix release` and runs it on a slim
# Debian base. See "Docker image" in README.md for building and running it.
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261027-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20261027-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20261027-slim
#
# Find builder and runner images on Docker Hub or on Hex's Build Server (Bob).
# We recommend using Bob's Web UI to find recent tags:
#
#   - https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian&sort=elixir_version,erlang_version,os_version
#
# We suggest using the same Debian version for both the builder and runner images.
#
# We suggest Debian/Ubuntu instead of Alpine to avoid production compatibility issues
# (such as DNS resolution failures, and dynamically linked NIFs/precompiled binaries).
#
# For finding packages in Debian, search on https://packages.debian.org/.

ARG ELIXIR_VERSION=1.20.5
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261027-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies (git for git-sourced deps, npm for JS packages,
# libvips for image uploads: Vix is built against the system's libvips)
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates nodejs npm \
    pkg-config libvips-dev \
  && rm -rf /var/lib/apt/lists/*

ENV VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies (an umbrella: each app's mix.exs declares its own)
COPY mix.exs mix.lock ./
COPY apps/firefly/mix.exs apps/firefly/
COPY apps/firefly_plugins/mix.exs apps/firefly_plugins/
COPY apps/firefly_web/mix.exs apps/firefly_web/
COPY apps/firefly_import/mix.exs apps/firefly_import/
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

# install JS packages (runtime dependencies only; Playwright is test-only)
COPY apps/firefly_web/assets/package.json apps/firefly_web/assets/package-lock.json apps/firefly_web/assets/
RUN npm ci --prefix apps/firefly_web/assets --omit=dev

COPY apps apps

# Compile the release
RUN mix compile

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release firefly

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

# postgresql-client-18 (from the PostgreSQL project's apt repository, set up
# by postgresql-common's script) for backups: pg_dump and pg_restore must
# match the server's major version (see Firefly.Backups).
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates tini \
    libvips42t64 postgresql-common \
  && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
  && apt-get install -y --no-install-recommends postgresql-client-18 \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"
# Backups are kept here (mount a volume) unless FIREFLY_BACKUP_STORAGE=s3
ENV FIREFLY_BACKUP_DIR="/app/backups"
# The commit this image is built from, shown by the version check:
# docker build --build-arg FIREFLY_GIT_SHA=$(git rev-parse HEAD) .
ARG FIREFLY_GIT_SHA=""
ENV FIREFLY_GIT_SHA=${FIREFLY_GIT_SHA}

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/firefly ./

USER nobody

LABEL org.opencontainers.image.title="Firefly" \
      org.opencontainers.image.description="The simpler Discourse alternative" \
      org.opencontainers.image.source="https://github.com/tznc/firefly" \
      org.opencontainers.image.vendor="tznc.dev" \
      org.opencontainers.image.licenses="Apache-2.0"

EXPOSE 4000

# tini reaps zombie processes and forwards signals for a clean shutdown
ENTRYPOINT ["/usr/bin/tini", "--"]

# Uploads are kept in /app/uploads (FIREFLY_UPLOAD_DIR) unless
# FIREFLY_UPLOAD_STORAGE=s3: mount a volume there to keep them.
# Run migrations first with: docker run ... firefly /app/bin/migrate
CMD ["/app/bin/server"]
