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
variables (see `config/runtime.exs`):

| Variable | Purpose |
|---|---|
| `DATABASE_URL`, `SECRET_KEY_BASE` | Required |
| `PHX_HOST` | Public host, default `firefly.tznc.dev` |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | GitHub login |
| `SENDGRID_API_KEY` | Outbound email |
| `EMAIL_FROM` | Sender, default `noreply@<PHX_HOST>` |
| `REPLY_EMAIL_DOMAIN` | Reply-by-email domain, default `reply.<PHX_HOST>` (needs an MX record pointing at SendGrid Inbound Parse) |
| `INBOUND_EMAIL_TOKEN` | Shared secret for the inbound webhook; set the SendGrid Inbound Parse URL to `https://<PHX_HOST>/inbound/sendgrid?token=<INBOUND_EMAIL_TOKEN>`. Reply-by-email is off without it |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_S3_REGION` | Attachment uploads |

Rate limits (login attempts, posting, uploads) are kept in memory per node; see
`FirestormWeb.RateLimit`.

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

Set `PLAYWRIGHT_CHROMIUM_PATH` to use an already-installed Chromium, and
`PW_TRACE=true` to record Playwright traces.

## Patrons

Firestorm was funded by [a
Kickstarter](https://www.kickstarter.com/projects/1003377429/firestorm-an-open-source-forum-in-phoenix-from-eli).

All of the patrons that made it possible are listed in [the PATRONS file](PATRONS.md).


## License

Firefly is licensed under the [Apache License 2.0](./LICENSE), © [tznc.dev](https://tznc.dev).
It contains code from Firestorm, originally MIT licensed; see [NOTICE](./NOTICE).
