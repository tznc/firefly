# Development image (used by docker-compose.yml).
FROM hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261027-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates curl nodejs npm inotify-tools && \
    rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /firestorm
COPY mix.exs mix.lock ./
RUN mix deps.get

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix assets

COPY . .
