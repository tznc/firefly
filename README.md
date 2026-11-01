<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./brand/firefly-icon-dark.svg">
    <img src="./brand/firefly-icon.svg" width="112" alt="Firefly logo">
  </picture>
</p>

<h1 align="center">Firefly</h1>

<p align="center">Created by <a href="https://tznc.dev">tznc.dev</a></p>

### An open-source forum engine built with Elixir, Phoenix and LiveView.

Firefly is created and maintained by [tznc.dev](https://tznc.dev). It builds on
the open-source Firestorm forum project.

## Development

Requirements: Elixir 1.20 / Erlang/OTP 29, Node.js 26 and PostgreSQL 18 (see `.tool-versions`).

The web UI is Phoenix LiveView styled with Tailwind CSS and daisyUI; the JSON
API lives under `/api/v1`.

```sh
npm ci --prefix assets
mix setup        # deps, database, seeds, assets
mix phx.server   # http://localhost:4000
```

Or with Docker: `docker compose up`.

### Production configuration

Firefly runs at <https://firefly.tznc.dev>. Production reads these environment
variables (see `config/runtime.exs`); all are prefixed `FIREFLY_`:

| Variable | Purpose |
|---|---|
| `FIREFLY_DATABASE_URL`, `FIREFLY_SECRET_KEY_BASE` | Required |
| `FIREFLY_DOMAIN` | Public domain (served over https on 443), default `firefly.tznc.dev` |
| `FIREFLY_GITHUB_CLIENT_ID`, `FIREFLY_GITHUB_CLIENT_SECRET` | GitHub login |
| `FIREFLY_SENDGRID_API_KEY` | Outbound email |
| `FIREFLY_EMAIL_FROM` | Sender, default `noreply@<FIREFLY_DOMAIN>` |
| `FIREFLY_REPLY_EMAIL_DOMAIN` | Reply-by-email domain, default `reply.<FIREFLY_DOMAIN>` (needs an MX record pointing at SendGrid Inbound Parse) |
| `FIREFLY_INBOUND_EMAIL_TOKEN` | Shared secret for the inbound webhook; set the SendGrid Inbound Parse URL to `https://<FIREFLY_DOMAIN>/inbound/sendgrid?token=<FIREFLY_INBOUND_EMAIL_TOKEN>`. Reply-by-email is off without it |
| `FIREFLY_AWS_ACCESS_KEY_ID`, `FIREFLY_AWS_SECRET_ACCESS_KEY`, `FIREFLY_AWS_S3_BUCKET`, `FIREFLY_AWS_S3_REGION` | Attachment uploads |
| `FIREFLY_PORT`, `FIREFLY_IPV6` | HTTP port (default 4000); `true` to listen on IPv6 |
| `FIREFLY_DATABASE_SSL`, `FIREFLY_DATABASE_IPV6`, `FIREFLY_DATABASE_POOL_SIZE` | Database TLS (default `true`), IPv6, pool size (default 10) |

Rate limits (login attempts, posting, uploads) are kept in memory per node; see
`FirestormWeb.RateLimit`.

### Docker image

`Dockerfile` builds a production image from a `mix release` (`Dockerfile.dev`
is the development image used by `docker compose`):

```sh
docker build -t firefly .

# run database migrations, then the server
docker run --rm --env-file .env firefly /app/bin/migrate
docker run -d -p 4000:4000 --env-file .env firefly
```

The image needs at least `FIREFLY_DATABASE_URL` and `FIREFLY_SECRET_KEY_BASE` (generate one with
`mix phx.gen.secret`); `FIREFLY_DOMAIN` sets the public domain. It listens on IPv4 port
`FIREFLY_PORT` (default 4000); set `FIREFLY_IPV6=true` to listen on IPv6 as well. Set
`FIREFLY_DATABASE_SSL=false` for a database without TLS. The other settings (GitHub
login, email, S3 uploads) are read from the environment in `config/runtime.exs`.

### Admin

`/admin` is a [Kaffy](https://github.com/aesmail/kaffy) admin UI, available to
users with the `admin` role (the seeds create `admin` / `password`).

### Tests

Page tests use [PhoenixTest](https://hexdocs.pm/phoenix_test); critical user
flows (log in, post, live replies, notifications, admin) also run end to end in
Chromium with [PhoenixTest.Playwright](https://hexdocs.pm/phoenix_test_playwright)
(`test/e2e`).

```sh
npx --prefix assets playwright install chromium   # once, for the e2e tests
mix test                   # everything
mix test --exclude e2e     # without the browser
mix test --only e2e        # just the browser flows
mix precommit              # compile --warnings-as-errors, format, credo, test
```

Set `FIREFLY_CHROMIUM_PATH` to use an already-installed Chromium, and
`FIREFLY_PW_TRACE=true` to record Playwright traces.

## Patrons

Firestorm was funded by [a
Kickstarter](https://www.kickstarter.com/projects/1003377429/firestorm-an-open-source-forum-in-phoenix-from-eli).

All of the patrons that made it possible are listed in [the PATRONS file](PATRONS.md).


## License

Firefly is licensed under the [Apache License 2.0](./LICENSE), © [tznc.dev](https://tznc.dev).
It contains code from Firestorm, originally MIT licensed; see [NOTICE](./NOTICE).
