![Firestorm](./firestorm-logo.png)

### An open-source forum engine, with an Elixir+Phoenix backend and an Elm frontend.

#### A community-funded project from [DailyDrip](https://www.dailydrip.com).

[![Build Status](https://semaphoreci.com/api/v1/dailydrip/firestorm/branches/master/badge.svg)](https://semaphoreci.com/dailydrip/firestorm)

This is the Firestorm Forum project. It's presently at version 0.10, nearly ready
for a 1.0 release. You can view the running forum at
<http://forum.firestormforum.org>.

## Development

Requirements: Elixir 1.20 / Erlang/OTP 29, Node.js 26 and PostgreSQL 18 (see `.tool-versions`).

```sh
npm ci --prefix assets
mix setup        # deps, database, seeds, assets
mix phx.server   # http://localhost:4000
```

Or with Docker: `docker compose up`.

### Tests

```sh
mix test                    # unit + controller tests
mix test --include feature  # also browser tests (needs Chrome + chromedriver; set CHROMEDRIVER_PATH if not on $PATH)
mix precommit               # compile --warnings-as-errors, format, credo, test
```

## Clients

### Elm

https://github.com/dailydrip/firestorm_elm

### Vue

https://github.com/dailydrip/firestorm_vue

### Flutter

https://github.com/dailydrip/firestorm_flutter

### React Native

https://github.com/dailydrip/firestorm_react_native


## Patrons

This project was funded by [a
Kickstarter](https://www.kickstarter.com/projects/1003377429/firestorm-an-open-source-forum-in-phoenix-from-eli).

All of the patrons that made it possible are listed in [the PATRONS file](PATRONS.md).


## License

Firestorm is [MIT Licensed](./LICENSE).
