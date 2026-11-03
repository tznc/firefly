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
npm ci --prefix apps/firefly_web/assets
mix setup        # deps, database, seeds, assets
mix phx.server   # http://localhost:4000
```

### Layout

Firefly is an umbrella of three apps; each declares the dependencies it uses,
and the shared configuration is in `config/`:

| App | Modules | What |
| --- | --- | --- |
| `apps/firefly` | `Firefly.*` | The domain: the `Firefly.Repo`, schemas and bounded contexts, jobs, email, authentication, the plugin layer and core plugins. Migrations and seeds are in `apps/firefly/priv/repo`. Depends on neither of the others |
| `apps/firefly_plugins` | `FireflyPlugins.*` | The sandbox uploaded plugins run in: QuickJS on WebAssembly via Wasmex (`priv/plugins/quickjs.wasm`, built from `wasm/quickjs`), and bundle validation. Registers itself with the domain at start |
| `apps/firefly_web` | `FireflyWeb.*` | The web interface: endpoint, router, LiveViews, controllers, channels, JSON API, Kaffy admin, assets and static files |

Inside `apps/firefly`, the domain is split into bounded contexts
(`Firefly.Accounts`, `Firefly.Discussion`, `Firefly.Messaging`,
`Firefly.Moderation`, `Firefly.Notifications`, `Firefly.Groups`,
`Firefly.TrustLevels`, `Firefly.Badges`, `Firefly.Directory`,
`Firefly.Uploads`, `Firefly.Rendering`, `Firefly.SiteSettings`, `Firefly.Analytics`, `Firefly.Reports`,
`Firefly.Plugins`): each one's root module and the modules it exports are
its only public API, enforced by the [boundary](https://hexdocs.pm/boundary)
compiler for the web and plugin apps and by `Firefly.BoundariesTest` between
contexts (see the `Firefly` module).

The domain reaches the web interface only through `Firefly.Endpoint` (the
configured endpoint: base URL, signing secret, broadcasts) and the sandbox
through `Firefly.Plugin.Sandbox` (registered at runtime), so it compiles and
its tests run on their own (`cd apps/firefly && mix test`).

Run `mix` tasks from the root: `mix compile`, `mix test`, `mix ecto.migrate`,
`mix assets.build` and the rest run in every app they apply to.

Or with Docker: `docker compose up`.

### Production configuration

Firefly runs at <https://firefly.tznc.dev>. Production reads these environment
variables (see `config/runtime.exs`); all are prefixed `FIREFLY_`:

| Variable | Purpose |
|---|---|
| `FIREFLY_DATABASE_URL`, `FIREFLY_SECRET_KEY_BASE` | Required |
| `FIREFLY_DOMAIN` | Public domain (served over https on 443), default `firefly.tznc.dev` |
| `FIREFLY_<PROVIDER>_CLIENT_ID`, `FIREFLY_<PROVIDER>_CLIENT_SECRET` | Social login, for `GITHUB`, `GOOGLE`, `DISCORD`, `FACEBOOK`, `X` and `SLACK`; each provider is offered only when both are set. Callback URL: `https://<domain>/auth/<provider>/callback` (lowercase) |
| `FIREFLY_APPLE_CLIENT_ID`, `FIREFLY_APPLE_TEAM_ID`, `FIREFLY_APPLE_KEY_ID`, `FIREFLY_APPLE_PRIVATE_KEY` | Sign in with Apple (the Services ID, team, key id and the `.p8` key's contents) |
| `FIREFLY_OIDC_DISCOVERY_URL`, `FIREFLY_OIDC_CLIENT_ID`, `FIREFLY_OIDC_CLIENT_SECRET` | Single sign-on with an OpenID Connect provider (its `.well-known/openid-configuration` URL; the secret is optional for public clients). Optional: `FIREFLY_OIDC_SCOPES` (default `openid email profile`), `FIREFLY_OIDC_NAME` (the button's name). Callback URL: `https://<domain>/auth/oidc/callback` |
| `FIREFLY_DISCOURSE_CONNECT_URL`, `FIREFLY_DISCOURSE_CONNECT_SECRET` | Single sign-on through a DiscourseConnect provider (its endpoint and the shared secret); optional `FIREFLY_DISCOURSE_CONNECT_NAME`. Which fields each login syncs is set under Logins in the site settings |
| `FIREFLY_SSO_ONLY` | `true`: single sign-on is the only way to log in (no social logins, passwords or registration form) |
| `FIREFLY_SENDGRID_API_KEY` | Outbound email |
| `FIREFLY_VAPID_PUBLIC_KEY`, `FIREFLY_VAPID_PRIVATE_KEY`, `FIREFLY_VAPID_SUBJECT` | Browser push notifications: a VAPID key pair (make one with `mix firefly.gen.vapid_keys`) and a contact URL (`mailto:admin@example.com`). Push is off and hidden without them |
| `FIREFLY_EMAIL_FROM` | Sender, default `noreply@<FIREFLY_DOMAIN>` |
| `FIREFLY_REPLY_EMAIL_DOMAIN` | Reply-by-email domain, default `reply.<FIREFLY_DOMAIN>` (needs an MX record pointing at SendGrid Inbound Parse) |
| `FIREFLY_INBOUND_EMAIL_TOKEN` | Shared secret for the inbound webhook; set the SendGrid Inbound Parse URL to `https://<FIREFLY_DOMAIN>/inbound/sendgrid?token=<FIREFLY_INBOUND_EMAIL_TOKEN>`. Reply-by-email is off without it |
| `FIREFLY_UPLOAD_STORAGE` | Where uploads are kept: `local` (default, a directory on disk) or `s3` |
| `FIREFLY_UPLOAD_DIR` | The local upload directory, default `uploads` under the working directory (`/app/uploads` in the Docker image: mount a volume there) |
| `FIREFLY_AWS_ACCESS_KEY_ID`, `FIREFLY_AWS_SECRET_ACCESS_KEY`, `FIREFLY_AWS_S3_BUCKET`, `FIREFLY_AWS_S3_REGION` | The S3 bucket for uploads, with `FIREFLY_UPLOAD_STORAGE=s3` (kept private: files are served through Firefly's access checks) |
| `FIREFLY_TAGS_ADMIN_ONLY` | `true` to let only admins create new tags (members can still use existing ones) |
| `FIREFLY_TRUSTED_PROXIES` | Reverse proxies or load balancers in front of Firefly (addresses or CIDR ranges, comma-separated, e.g. `10.0.0.0/8`). Their `X-Forwarded-For` header then gives the client IP for per-IP rate limits; without it, every visitor behind a proxy shares the proxy's address. Default: none (the header is ignored) |
| `FIREFLY_PORT`, `FIREFLY_IPV6` | HTTP port (default 4000); `true` to listen on IPv6 |
| `FIREFLY_DATABASE_SSL`, `FIREFLY_DATABASE_IPV6`, `FIREFLY_DATABASE_POOL_SIZE` | Database TLS (default `true`), IPv6, pool size (default 10) |

Rate limits (login attempts, posting, uploads) are kept in memory per node; see
`Firefly.RateLimit`.

Image uploads are processed with [libvips](https://www.libvips.org) (through
[Vix](https://github.com/akash-akya/vix)), built against the system library:
install it (`apt-get install libvips-dev`, `brew install vips`) and set
`VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` before `mix deps.compile`. The
Docker images include it.

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

### Plugins

Staff install and manage plugins at `/staff/plugins`: core plugins written
in Elixir, and third-party JavaScript plugins that run sandboxed in QuickJS
on WebAssembly. See [PLUGINS.md](PLUGINS.md) for the plugin API.

### Tests

Page tests use [PhoenixTest](https://hexdocs.pm/phoenix_test); critical user
flows (log in, post, live replies, notifications, admin) also run end to end in
Chromium with [PhoenixTest.Playwright](https://hexdocs.pm/phoenix_test_playwright)
(`apps/firefly_web/test/e2e`). Each app's tests are in its `test/`; shared
fixtures (`Firefly.Fixtures`, `Firefly.DataCase`) are in `apps/firefly/test/support`.

```sh
npx --prefix apps/firefly_web/assets playwright install chromium   # once, for the e2e tests
mix test                   # every app
mix test --exclude e2e     # without the browser
(cd apps/firefly && mix test)                  # one app
(cd apps/firefly_web && mix test --only e2e)   # just the browser flows
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
