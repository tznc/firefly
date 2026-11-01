<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./brand/firefly-icon-dark.svg">
    <img src="./brand/firefly-icon.svg" width="112" alt="Firefly logo">
  </picture>
</p>

<h1 align="center">Firefly</h1>

### An open-source forum engine built with Elixir, Phoenix and LiveView.

Firefly builds on the Firestorm Forum project, which reached version 0.10, nearly
ready for a 1.0 release. You can view the original Firestorm forum at
<http://forum.firestormforum.org>.

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

## Clients

These clients were built for Firestorm.

### Elm

https://github.com/dailydrip/firestorm_elm

### Vue

https://github.com/dailydrip/firestorm_vue

### Flutter

https://github.com/dailydrip/firestorm_flutter

### React Native

https://github.com/dailydrip/firestorm_react_native


## Patrons

Firestorm was funded by [a
Kickstarter](https://www.kickstarter.com/projects/1003377429/firestorm-an-open-source-forum-in-phoenix-from-eli).

All of the patrons that made it possible are listed in [the PATRONS file](PATRONS.md).


## License

Firefly is licensed under the [Apache License 2.0](./LICENSE). It contains code from
Firestorm, originally MIT licensed by DailyDrip; see [NOTICE](./NOTICE).
