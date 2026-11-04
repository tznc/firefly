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

Requirements: Elixir 1.20 / Erlang/OTP 29 and Node.js 26 (see `.tool-versions`),
and PostgreSQL 17 or newer with the [pgvector](https://github.com/pgvector/pgvector)
extension available. The migrations create the extension, so the database user
needs the right to (or create it beforehand: `CREATE EXTENSION vector`).

Development, the tests, CI and `docker compose` use the
[`supabase/postgres`](https://hub.docker.com/r/supabase/postgres) image
(PostgreSQL 17 with pgvector; only the database image, none of Supabase's
other services):

```sh
docker run -d --name supa-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 supabase/postgres:17.11.0.018
```

Its superuser is `supabase_admin`; `POSTGRES_PASSWORD` also sets the password of
the `postgres` role, which Firefly connects as by default: it isn't a superuser
but may create databases and extensions. Leave `POSTGRES_USER` and `POSTGRES_DB`
unset (the image's init scripts depend on them), and give it a few seconds on
first start, while it sets itself up. `FIREFLY_POSTGRES_HOST`, `_PORT`, `_USER`
and `_PASSWORD` point development and the tests at another server.

The web UI is Phoenix LiveView styled with Tailwind CSS and daisyUI; the REST
API lives under `/api/v1` (see "API" below).

```sh
npm ci --prefix apps/firefly_web/assets
mix setup        # deps, database, seeds, assets
mix phx.server   # http://localhost:4000
```

### Layout

Firefly is an umbrella of four apps; each declares the dependencies it uses,
and the shared configuration is in `config/`:

| App | Modules | What |
| --- | --- | --- |
| `apps/firefly` | `Firefly.*` | The domain: the `Firefly.Repo`, schemas and bounded contexts, jobs, email, authentication, the plugin layer and core plugins. Migrations and seeds are in `apps/firefly/priv/repo`. Depends on neither of the others |
| `apps/firefly_plugins` | `FireflyPlugins.*` | The sandbox uploaded plugins run in: QuickJS on WebAssembly via Wasmex (`priv/plugins/quickjs.wasm`, built from `wasm/quickjs`), and bundle validation. Registers itself with the domain at start |
| `apps/firefly_web` | `FireflyWeb.*` | The web interface: endpoint, router, LiveViews (the staff admin included), controllers, channels, JSON API, assets and static files |
| `apps/firefly_import` | `FireflyImport.*` | Importers from other forums and platforms (see "Importing"): each reads its source and hands the records to the domain's `Firefly.Import`. Apart so their database drivers stay out of the domain |

Inside `apps/firefly`, the domain is split into bounded contexts
(`Firefly.Accounts`, `Firefly.Discussion`, `Firefly.Messaging`,
`Firefly.Moderation`, `Firefly.Notifications`, `Firefly.Groups`,
`Firefly.TrustLevels`, `Firefly.Badges`, `Firefly.Directory`,
`Firefly.Uploads`, `Firefly.Rendering`, `Firefly.SiteSettings`, `Firefly.Analytics`, `Firefly.Reports`, `Firefly.Backups`, `Firefly.Upgrades`, `Firefly.Embedding`, `Firefly.Chat`, `Firefly.AI`,
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
| `FIREFLY_SAML_SP_KEY`, `FIREFLY_SAML_SP_CERT` | The private key and certificate (PEM) SAML login requests are signed with, when "Sign login requests" is on. SAML itself is set up under SAML in the site settings (the identity provider's metadata URL or XML, attribute mapping); give the identity provider `https://<domain>/saml/metadata` (assertion consumer service: `https://<domain>/auth/saml/acs`) |
| `FIREFLY_LDAP_HOST`, `FIREFLY_LDAP_BASE_DN` | Logging in with an LDAP directory (OpenLDAP, Active Directory...): its host and where to search for people. Optional: `FIREFLY_LDAP_PORT`, `FIREFLY_LDAP_ENCRYPTION` (`starttls`, the default, `ldaps` or `none`), `FIREFLY_LDAP_VERIFY` (`false` skips certificate checks), `FIREFLY_LDAP_CA_CERT_FILE` (default: the system's CAs), `FIREFLY_LDAP_BIND_DN` and `FIREFLY_LDAP_BIND_PASSWORD` (the account searches run as; default anonymous), `FIREFLY_LDAP_USER_FILTER` (default `(uid=%{username})`; Active Directory: `(sAMAccountName=%{username})`), `FIREFLY_LDAP_UID_ATTRIBUTE` (default `entryUUID`; Active Directory: `objectGUID`), `_USERNAME_ATTRIBUTE`, `_EMAIL_ATTRIBUTE`, `_NAME_ATTRIBUTE` (default `uid`, `mail`, `cn`), `FIREFLY_LDAP_GROUP_BASE_DN` (syncs groups by name), `FIREFLY_LDAP_GROUP_FILTER` (default `(member=%{dn})`), `FIREFLY_LDAP_GROUP_NAME_ATTRIBUTE` (default `cn`), `FIREFLY_LDAP_NAME` (the button's name). "LDAP replaces local passwords" in the site settings turns password logins off |
| `FIREFLY_SSO_ONLY` | `true`: single sign-on is the only way to log in (no social logins, passwords or registration form) |
| `FIREFLY_SENDGRID_API_KEY` | Outbound email |
| `FIREFLY_VAPID_PUBLIC_KEY`, `FIREFLY_VAPID_PRIVATE_KEY`, `FIREFLY_VAPID_SUBJECT` | Browser push notifications: a VAPID key pair (make one with `mix firefly.gen.vapid_keys`) and a contact URL (`mailto:admin@example.com`). Push is off and hidden without them |
| `FIREFLY_EMAIL_FROM` | Sender, default `noreply@<FIREFLY_DOMAIN>` |
| `FIREFLY_REPLY_EMAIL_DOMAIN` | Reply-by-email domain, default `reply.<FIREFLY_DOMAIN>` (needs an MX record pointing at SendGrid Inbound Parse) |
| `FIREFLY_INBOUND_EMAIL_TOKEN` | Shared secret for the inbound webhook; set the SendGrid Inbound Parse URL to `https://<FIREFLY_DOMAIN>/inbound/sendgrid?token=<FIREFLY_INBOUND_EMAIL_TOKEN>`. Reply-by-email is off without it |
| `FIREFLY_UPLOAD_STORAGE` | Where uploads are kept: `local` (default, a directory on disk) or `s3` |
| `FIREFLY_UPLOAD_DIR` | The local upload directory, default `uploads` under the working directory (`/app/uploads` in the Docker image: mount a volume there) |
| `FIREFLY_AWS_ACCESS_KEY_ID`, `FIREFLY_AWS_SECRET_ACCESS_KEY`, `FIREFLY_AWS_S3_BUCKET`, `FIREFLY_AWS_S3_REGION` | The S3 bucket for uploads, with `FIREFLY_UPLOAD_STORAGE=s3` (kept private: files are served through Firefly's access checks) |
| `FIREFLY_BACKUP_STORAGE` | Where backups (`/staff/backups`) are kept: `local` (default) or `s3` (the uploads' bucket, under `FIREFLY_BACKUP_S3_PREFIX`, default `backups/`) |
| `FIREFLY_BACKUP_DIR` | The local backup directory, default `backups` under the working directory (`/app/backups` in the Docker image: mount a volume there) |
| `FIREFLY_PG_BIN_DIR` | Where `pg_dump` and `pg_restore` are, for backups; they must be the database's major version or newer (the Docker image has PostgreSQL 18's, for servers up to 18). Default: the newest `/usr/lib/postgresql/*/bin`, else the `PATH` |
| `FIREFLY_GIT_SHA` | The commit the code was built from, shown with the version (the Docker image sets it from the `FIREFLY_GIT_SHA` build argument) |
| `FIREFLY_UPDATE_REPO` | The GitHub repository whose latest release the daily version check compares with (default `tznc/firefly`); the check is off with the `version_check` site setting |
| `FIREFLY_TAGS_ADMIN_ONLY` | `true` to let only admins create new tags (members can still use existing ones); pins the "Only admins create tags" site setting |
| `FIREFLY_SETTING_<KEY>` | Pins any site setting (e.g. `FIREFLY_SETTING_TITLE`, `FIREFLY_SETTING_ALLOW_REGISTRATIONS=false`): the value wins over the admin's, shown read-only at `/staff/settings` |
| `FIREFLY_TRUSTED_PROXIES` | Reverse proxies or load balancers in front of Firefly (addresses or CIDR ranges, comma-separated, e.g. `10.0.0.0/8`). Their `X-Forwarded-For` header then gives the client IP for per-IP rate limits; without it, every visitor behind a proxy shares the proxy's address. Default: none (the header is ignored) |
| `FIREFLY_AI_ENCRYPTION_KEY` | The secret AI providers' API keys (set at `/staff/ai`) are encrypted with at rest. Default: derived from `FIREFLY_SECRET_KEY_BASE`; changing either makes stored keys unreadable (enter them again) |
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
docker build -t firefly --build-arg FIREFLY_GIT_SHA=$(git rev-parse HEAD) .

# run database migrations, then the server
docker run --rm --env-file .env firefly /app/bin/migrate
docker run -d -p 4000:4000 --env-file .env firefly
```

The image needs at least `FIREFLY_DATABASE_URL` and `FIREFLY_SECRET_KEY_BASE` (generate one with
`mix phx.gen.secret`); `FIREFLY_DOMAIN` sets the public domain. It listens on IPv4 port
`FIREFLY_PORT` (default 4000); set `FIREFLY_IPV6=true` to listen on IPv6 as well. Set
`FIREFLY_DATABASE_SSL=false` for a database without TLS. Any PostgreSQL 17 or
newer with pgvector works (a managed one too); the `supabase/postgres` image
above is the recommended one to run yourself. The other settings (GitHub
login, email, S3 uploads) are read from the environment in `config/runtime.exs`.

### API

`/api/v1` is a REST API covering what the UI does: categories, threads and
their lists, posts (likes, bookmarks, flags, polls, accepted answers), tags,
users and the directory, notifications, private messages, chat, groups,
search, uploads, the review queue and the admin settings, webhooks and
badges. Its reference is at `/api/v1/docs`, rendered from the OpenAPI 3.1
document at `/api/v1/openapi.json`.

Requests authenticate with an API key, `Authorization: Bearer <key>`;
without one they read as a visitor. A key acts as its user, with that
user's permissions, limited to the key's scopes (`read`, `write`,
`topics:write`, `messages:write`, `chat:write`, `uploads:write`,
`users:write`, `notifications:write`, `admin`). Members make their own keys
in Settings > API keys; admins see every key and make global keys at
`/staff/api-keys`, which act as the user each request names in the
`Api-Username` header. A key can expire, be limited to addresses or CIDR
ranges and carry its own requests-per-minute limit (otherwise the
`api_rate_limit` site setting), and only its hash is stored: the key itself
is shown once. `POST /api/v1/auth/identity` trades a username and password
for a new full-scope key.

Lists are paginated with `limit` (up to 100) and `cursor` (from
`meta.next_cursor`); errors are `application/problem+json` (RFC 9457). The
MCP server at `/mcp` uses the same keys, with the `read` scope.

### Accessibility

Every page is held to WCAG 2.1 AA by
[axe-core](https://github.com/dequelabs/axe-core) in the end-to-end tests
(`FireflyWeb.E2E.AccessibilityTest`), in both themes and as a visitor and
as staff: any serious or critical violation fails the suite. There is a
skip link, the navigation is a labelled landmark, live regions announce
flashes and new content, the shortcuts help is a native `dialog` (so the
browser traps focus), focus outlines are never removed, and
`prefers-reduced-motion` turns animations and smooth scrolling off.

Keyboard shortcuts, as in Discourse: `?` opens the list, `j`/`k` move
through the topics or posts, `g` then `h`/`c`/`n`/`u`/`t`/`b`/`m`/`p`
goes to the home page, categories, new, unread, top, bookmarks, messages
or chat, `r` replies, `l` likes and `b` bookmarks the post in hand, `/`
focuses the search and `Esc` closes. They never fire while you are typing
in a field, and members can turn them off in their interface settings.

### Languages

The interface is translated with [Gettext](https://hexdocs.pm/gettext)
(`apps/firefly_web/priv/gettext`), in three domains: `default` (the
interface), `errors` (validation messages) and `times` (month and day
names, used by `FireflyWeb.Locale.strftime/2`). Shipped locales: English,
Spanish, French, German, Brazilian Portuguese, Japanese, Simplified
Chinese and Arabic.

**The translations outside English are machine quality and still need a
native speaker's review**; the interface says so where members pick their
language. Arabic is deliberately partial: it covers the navigation and
short labels, which is enough to exercise right-to-left layout (`<html
dir="rtl">`), and the rest falls back to English.

A reader's language is the first of: `?lang=`, their own choice (Settings
> Interface), what an earlier request resolved (the session), the
browser's `Accept-Language`, and the site's default (Language, under Site
in the site settings). See `FireflyWeb.Locale`.

Extracted so far: the shared chrome (navigation, notices, flashes, the
theme toggle), the login, registration and password flows, the interface
settings and every validation error. The rest of the interface is still
English in the source; `FireflyWeb.I18nTest` lists the localized files and
fails if an English literal creeps back into one, and if any `.po` file
drifts from its `.pot`. To add strings: wrap them in `gettext(...)`, add
the file to that list, then run

```sh
mix gettext.extract --merge
```

### Search engines

`robots.txt` is generated (crawl rules, the staff, account and private
paths, the admin's extra rules and a link to the sitemap), and
`/sitemap.xml` indexes paginated sitemaps of public topics, categories and
tags with their last change. Every page carries a canonical URL,
OpenGraph and Twitter card tags and, where it applies, JSON-LD
(`DiscussionForumPosting` with its replies, `BreadcrumbList`, and
`WebSite` with a `SearchAction` plus `Organization` on the home page).
Private categories, archived topics, search results and members' personal
lists say `noindex`; so do profiles, the directory, groups and badges
unless "Index member pages" is on, and nothing is indexed at all with
"Allow indexing" off (both under Search engines in the site settings).

Crawlers (by `User-Agent`) get topics as plain server-rendered pages that
need no JavaScript, long ones split into `?page=` pages linked with
`rel="prev"`/`rel="next"`; readers with a browser get the LiveView as
before, whose first render is server-rendered too.

### Admin

Staff run the forum from `/staff` (the seeds create `admin` / `password`;
the old `/admin` URLs redirect there). Its sidebar groups every admin page
into sections (overview, people, content, moderation, communication,
configuration, maintenance), and its search finds pages and site settings.

Staff are admins and moderators. Moderators handle the review queue,
flags, penalties, new accounts and the screening lists, and see the staff
log; admins also run the site. Grant either role from a user's admin page
(or with DiscourseConnect's flags).

- **Users** (`/staff/users`): every account, filtered (active, new, staff,
  suspended, silenced, waiting for approval) and searched by username,
  name, email or IP address. Each account's page shows its email and
  logins, trust level, groups, penalties, the IP addresses it used (and
  other accounts seen there), API keys and notifications, and lets staff
  edit it, approve or reject it (with "Staff approve new accounts" on),
  silence or suspend it, reset its two-factor, send a password reset or a
  notice, grant or revoke admin and moderator, anonymize it, delete it
  with its posts, merge it into another account, or impersonate it.
  Impersonating shows a banner on every page to stop; admins and
  moderators can't be impersonated.
- **Categories** (`/staff/categories`): order them, and set which groups
  may see each and whether they may start threads, only reply or only
  read, and the notification level new members start at.
- **Groups**, **Badges**, **Plugins**, **Webhooks** and the rest are in the
  sidebar.
- **Emails** (`/staff/emails`): the log of every email sent, skipped or
  failed (kept `email_log_days`), a test email, and each template
  previewed with sample data.
- **Site settings** (`/staff/settings`): over 180 typed settings (text,
  numbers, switches, choices, lists, colors, uploads) in categories and
  sections, searchable, filterable to the ones changed from their
  default, each with its default, a reset and its history from the staff
  log. Any setting can be pinned by the deployment with
  `FIREFLY_SETTING_<KEY>` (shown read-only). Export them as JSON or YAML
  and import either; secrets are never shown or exported.
- **Screening** (`/staff/screening`): email addresses or patterns, IP
  addresses or ranges and URL domains that are blocked from signing up or
  posting. Each block is counted and recorded in the staff log.

Every admin action is recorded in the staff log (`/staff/log`).

### Plugins

Staff install and manage plugins at `/staff/plugins`: core plugins written
in Elixir, and third-party JavaScript plugins that run sandboxed in QuickJS
on WebAssembly. See [PLUGINS.md](PLUGINS.md) for the plugin API.

### Importing

`mix firefly.import <source> [options]` imports another site's content:
users (without passwords: they reset theirs, use a magic link or the same
single sign-on), groups, categories, tags, topics and posts with their
original authors and dates, likes, bookmarks, polls, accepted answers,
private messages and uploads, plus permalinks that redirect the old URLs.
Run it again to resume it or pick up what's new; `--dry-run` shows what it
would do. In the Docker image: `bin/firefly eval
'FireflyImport.CLI.main(~w(<source> [options]))'`. Admins follow the runs at
`/staff/import`.

| Source | Reads |
| --- | --- |
| `discourse` | its PostgreSQL database (`--source-url`, a running site's or a backup's restored dump) and uploads directory (`--uploads-dir`) |
| `phpbb` | phpBB 3.x's MySQL/MariaDB database (`--source-url mysql://...`, `--table-prefix`) and `files/` directory (`--files-dir`) |
| `vbulletin` | vBulletin 4's or 5's MySQL/MariaDB database (`--source-url`, `--table-prefix`), attachments from it or `--attachments-dir` |
| `nodebb` | NodeBB's MongoDB (`--mongo-url`) or Redis (`--redis-url`) database and `public/uploads` (`--uploads-dir`) |
| `slack` | a workspace export ZIP (`--path`); `--as chat` (default) or `--as forum`; `--token` to download shared files |
| `discord` | DiscordChatExporter JSON files (`--path`); `--as chat` or `--as forum`; `--download` for attachments on Discord's CDN |
| `github` | a repository's Discussions through the GraphQL API (`--repo owner/name --token ...`) |

### AI

AI features are off until an admin turns them on at `/staff/ai`, adds a
model provider and picks the provider serving each feature. Providers are
pluggable adapters (`Firefly.AI.Provider`): the Anthropic Messages API, and
any OpenAI-compatible API (OpenAI, or a self-hosted Ollama, vLLM or LM
Studio by base URL; tick "Allow private addresses" for one on the local
network). Model ids are whatever the provider calls them, for example
`gpt-4o-mini` at `https://api.openai.com/v1` or `llama3.1` at
`http://localhost:11434/v1`. Members get a daily number of AI requests by
trust level (site settings, AI section), and every request is logged with
its tokens (the `AI usage` report). Prompts are built in and can be
overridden in the AI prompts site settings.

The features: topic summaries on long threads (cached until enough new
posts) and chat catch-ups of unread messages; translating a post or chat
message into the reader's browser language (cached); triage, which rates
new and flagged posts for toxicity, spam and sentiment in the background
and flags, hides or tags them past configurable thresholds (logged as the
system's; the `Sentiment` report and dashboard chart); and composer
helpers (proofread, suggest a title or tags). Only content the member
asking may read is ever sent, never private messages, and every AI output
is labelled as AI-generated.

Semantic search embeds posts (with an OpenAI-compatible provider's
embedding model) into a pgvector column, as they're posted and edited and
by a background backfill; the search page then offers a "Semantic" toggle
(hybrid: full-text and vector results fused by reciprocal rank), and topics
end with related topics. Results follow the same permission rules as
search.

The MCP server (off by default: the `mcp_enabled` setting) lets AI
assistants read the forum over the Model Context Protocol (Streamable HTTP)
at `/mcp`, with a member's API token as `Authorization: Bearer <token>`:
tools `search`, `read_topic`, `list_latest` and `get_user_profile`, which
see only what that member may read.

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

The phpBB, vBulletin and NodeBB importers' tests read MySQL, MongoDB and
Redis databases, so they're left out unless included (CI runs them):

```sh
docker run -d -p 3306:3306 -e MARIADB_ROOT_PASSWORD=root mariadb:11
docker run -d -p 27017:27017 mongo:7
docker run -d -p 6379:6379 redis:7
mix test --include import_mysql --include import_mongo --include import_redis
```

The LDAP login tests need a directory, so they're left out unless included
(CI runs them too; `FIREFLY_TEST_LDAP_HOST` points them elsewhere):

```sh
docker run -d -p 10389:10389 -p 10636:10636 ghcr.io/rroemhild/docker-test-openldap:master
mix test --include ldap
```

`FIREFLY_IMPORT_MYSQL_URL`, `FIREFLY_IMPORT_MONGO_URL` and
`FIREFLY_IMPORT_REDIS_URL` point them elsewhere.

## Patrons

Firestorm was funded by [a
Kickstarter](https://www.kickstarter.com/projects/1003377429/firestorm-an-open-source-forum-in-phoenix-from-eli).

All of the patrons that made it possible are listed in [the PATRONS file](PATRONS.md).


## License

Firefly is licensed under the [Apache License 2.0](./LICENSE), © [tznc.dev](https://tznc.dev).
It contains code from Firestorm, originally MIT licensed; see [NOTICE](./NOTICE).
