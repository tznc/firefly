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
`Firefly.Uploads`, `Firefly.Rendering`, `Firefly.SiteSettings`, `Firefly.Analytics`, `Firefly.Reports`, `Firefly.Backups`, `Firefly.Upgrades`, `Firefly.Health`, `Firefly.Jobs`, `Firefly.Embedding`, `Firefly.Chat`, `Firefly.AI`,
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
| `FIREFLY_MAIL_ADAPTER` | Outbound email: `smtp`, `ses`, `sendgrid`, `mailgun`, `postmark` or `local`, with that adapter's variables (see "Email"). Required: production won't start without one |
| `FIREFLY_VAPID_PUBLIC_KEY`, `FIREFLY_VAPID_PRIVATE_KEY`, `FIREFLY_VAPID_SUBJECT` | Browser push notifications: a VAPID key pair (make one with `mix firefly.gen.vapid_keys`) and a contact URL (`mailto:admin@example.com`). Push is off and hidden without them |
| `FIREFLY_EMAIL_FROM` | Sender, default `noreply@<FIREFLY_DOMAIN>` |
| `FIREFLY_REPLY_EMAIL_DOMAIN` | Reply-by-email domain, default `reply.<FIREFLY_DOMAIN>` (needs an MX record pointing at SendGrid Inbound Parse) |
| `FIREFLY_INBOUND_EMAIL_TOKEN` | Shared secret for the inbound webhook; set the SendGrid Inbound Parse URL to `https://<FIREFLY_DOMAIN>/inbound/sendgrid?token=<FIREFLY_INBOUND_EMAIL_TOKEN>`. Reply-by-email is off without it |
| `FIREFLY_UPLOAD_STORAGE` | Where uploads are kept: `local` (default, a directory on disk) or `s3` |
| `FIREFLY_UPLOAD_DIR` | The local upload directory, default `uploads` under the working directory (`/app/uploads` in the Docker image: mount a volume there) |
| `FIREFLY_AWS_ACCESS_KEY_ID`, `FIREFLY_AWS_SECRET_ACCESS_KEY`, `FIREFLY_AWS_S3_BUCKET`, `FIREFLY_AWS_S3_REGION` | The S3 bucket for uploads, with `FIREFLY_UPLOAD_STORAGE=s3` (kept private: files are served through Firefly's access checks) |
| `FIREFLY_CLAMAV_HOST`, `FIREFLY_CLAMAV_PORT` | Virus scanning of uploads with a [clamd](https://docs.clamav.net) daemon over TCP (port default 3310), off unless the host is set (see "Uploads" below) |
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
| `FIREFLY_METRICS_PORT`, `FIREFLY_METRICS_IP`, `FIREFLY_METRICS_TOKEN` | Prometheus metrics, off by default: a port of their own for `/metrics` (bound to `FIREFLY_METRICS_IP`, default `0.0.0.0`), and/or a bearer token that serves `/metrics` on the main port too (see "Metrics") |
| `OTEL_EXPORTER_OTLP_ENDPOINT` and the other standard `OTEL_*` variables | OpenTelemetry traces over OTLP, off without an endpoint; `FIREFLY_OTEL_METRICS=true` and `FIREFLY_OTEL_LOGS=true` add metrics and logs (experimental; see "Observability") |
| `FIREFLY_JOBS_<QUEUE>` | Background job concurrency on this node per queue (`DEFAULT`, `MAILERS`, `NOTIFICATIONS`, `WEBHOOKS`, `PLUGINS`, `AI`, `MAINTENANCE`), e.g. `FIREFLY_JOBS_MAILERS=20`; `0` leaves that queue to other nodes (see "Background jobs") |
| `FIREFLY_DRAIN_DELAY_MS` | On shutdown, how long `/ready` fails before the server stops listening (default 0), so load balancers take the node out first (see "Monitoring") |
| `FIREFLY_DATABASE_SSL`, `FIREFLY_DATABASE_IPV6`, `FIREFLY_DATABASE_POOL_SIZE` | Database TLS (default `true`), IPv6, pool size (default 10) |
| `FIREFLY_CLUSTER`, `FIREFLY_CLUSTER_NAME`, `FIREFLY_CLUSTER_HEARTBEAT_MS`, `FIREFLY_NODE_HOST`, `FIREFLY_DIST_PORT`, `RELEASE_COOKIE` | Running several nodes as one cluster, off by default (see "Running several nodes") |

Rate limits (login attempts, posting, uploads) are kept in memory per node; see
`Firefly.RateLimit` and "Running several nodes".

Image uploads are processed with [libvips](https://www.libvips.org) (through
[Vix](https://github.com/akash-akya/vix)), built against the system library:
install it (`apt-get install libvips-dev`, `brew install vips`) and set
`VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` before `mix deps.compile`. The
Docker images include it.

Uploads: the type comes from the file's content, and a file whose name or
claimed type says otherwise is refused. SVG images are rendered to PNGs (so no
script, `foreignObject`, event handler or external reference survives); other
files than images are served as downloads (`Content-Disposition: attachment`),
everything with `X-Content-Type-Options: nosniff` and a sandboxing CSP. With
`FIREFLY_CLAMAV_HOST` set, a new upload is served to no one until clamd has
scanned it (a background job, retried while clamd is unreachable); an infected
file is quarantined, recorded in the staff log and refused from then on.

### Docker image

`Dockerfile` builds a production image from a `mix release` (`Dockerfile.dev`
is the development image used by `docker compose`):

```sh
docker build -t firefly --build-arg FIREFLY_GIT_SHA=$(git rev-parse HEAD) .

# run database migrations, then the server
docker run --rm --env-file .env firefly /app/bin/migrate
docker run -d -p 4000:4000 --env-file .env firefly
```

The image needs at least `FIREFLY_DATABASE_URL`, `FIREFLY_SECRET_KEY_BASE` (generate one with
`mix phx.gen.secret`) and a mail adapter (`FIREFLY_MAIL_ADAPTER`, see "Email"); `FIREFLY_DOMAIN` sets the public domain. It listens on IPv4 port
`FIREFLY_PORT` (default 4000); set `FIREFLY_IPV6=true` to listen on IPv6 as well. Set
`FIREFLY_DATABASE_SSL=false` for a database without TLS. Any PostgreSQL 17 or
newer with pgvector works (a managed one too); the `supabase/postgres` image
above is the recommended one to run yourself. The other settings (GitHub
login, email, S3 uploads) are read from the environment in `config/runtime.exs`.

The image's `HEALTHCHECK` runs `/app/bin/healthcheck`, which asks the server
for `GET /health` over bash's `/dev/tcp`: the image has no curl, and
`bin/firefly rpc` would start a second VM on every check. Give it a path to
check readiness instead (`/app/bin/healthcheck /ready`), e.g. as a compose
`healthcheck` that `depends_on: condition: service_healthy` waits for.

### Running several nodes

Several Firefly nodes can serve one forum behind a load balancer. They share
the database and uploads (use `FIREFLY_UPLOAD_STORAGE=s3`, or one shared
volume), and with clustering on they form one Erlang cluster, so what one
node broadcasts reaches the others: live updates (new posts, notifications,
chat, presence) and cache invalidation (site settings, emoji, watched words,
plugins, read-only mode). Without clustering, each node only sees its own
changes until it restarts.

Nodes find each other through the database (libcluster's Postgres strategy):
each `LISTEN`s on a Postgres channel and `NOTIFY`s its node name there every
few seconds; the others connect to it. No DNS, headless service or
Kubernetes API access is needed. It connects with the repo's settings
(`FIREFLY_DATABASE_URL`, `FIREFLY_DATABASE_SSL`, `FIREFLY_DATABASE_IPV6`)
over two extra connections per node, outside the pool. A connection pooler
in transaction mode (PgBouncer, Supavisor) drops `LISTEN`: point Firefly at
the database itself, or at a session-mode port.

| Variable | Purpose |
| --- | --- |
| `FIREFLY_CLUSTER` | `postgres` turns clustering on; unset (or `none`) leaves each node on its own |
| `FIREFLY_CLUSTER_NAME` | Deployments sharing a database server use their own channel, `firefly_cluster_<name>` (`a-z`, `0-9`, `_`); default `firefly_cluster` |
| `FIREFLY_CLUSTER_HEARTBEAT_MS` | How often a node announces itself (default 5000): how soon a new node is found |
| `RELEASE_COOKIE` | Required with clustering: the secret nodes authenticate each other with, the same on every node, at least 32 characters (`openssl rand -hex 32`). The release refuses to start clustered without one, or with the one built into the image |
| `FIREFLY_NODE_HOST` | The address other nodes reach this one at (its node name is `firefly@<host>`). Default: the machine's first address (`hostname -i`); in Kubernetes, the pod IP |
| `FIREFLY_DIST_PORT` | The port the node listens on for other nodes (default 9100) |

Each node listens on EPMD's port 4369 (the Erlang port mapper) and on
`FIREFLY_DIST_PORT`; both must be open between the nodes, and only between
them: anyone who can reach those ports with the cookie controls the node.
Erlang distribution isn't encrypted, so keep the nodes on a private network.
Remote consoles (`bin/firefly remote`) and `bin/firefly rpc` work as before
from inside a node's container.

What is and isn't cluster-wide:

| | |
| --- | --- |
| Cluster-wide | PubSub: live pages, notifications, chat and presence; cache invalidation; the database and everything in it (sessions are cookies, so any node serves any request) |
| Per node | Rate limits (Hammer's in-memory buckets): with N nodes behind a round-robin balancer, a client gets up to N times each limit. Lower the limits (the `rate_limit_*` site settings) or use sticky sessions if that matters. Also per node: metrics, the in-memory link preview and report caches, and the plugin sandbox's instances |
| Not needed | Background work (thread timers and reminders, periodic jobs, plugin events and jobs, webhook deliveries) is claimed through the database (`SKIP LOCKED`, `Firefly.JobRuns`), so it runs once whichever nodes are up, clustered or not. Backups and restores are one at a time per node: start them from one node |

A node that was cut off from the others while settings changed keeps its
stale caches until the next change or a restart. `/ready` reports
`"cluster": {"enabled": true, "nodes": 2}` (the other nodes this one is
connected to) without ever failing on it, and nodes joining and leaving are
logged and counted (`firefly_cluster_node_count`,
`firefly_cluster_nodes_connected`).

A Kubernetes example (no headless service needed):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: firefly}
spec:
  replicas: 3
  selector: {matchLabels: {app: firefly}}
  template:
    metadata: {labels: {app: firefly}}
    spec:
      containers:
        - name: firefly
          image: firefly:latest
          ports:
            - {name: http, containerPort: 4000}
            - {name: epmd, containerPort: 4369}
            - {name: dist, containerPort: 9100}
          env:
            - {name: FIREFLY_CLUSTER, value: postgres}
            - name: FIREFLY_NODE_HOST
              valueFrom: {fieldRef: {fieldPath: status.podIP}}
            - name: RELEASE_COOKIE
              valueFrom: {secretKeyRef: {name: firefly, key: release-cookie}}
            # FIREFLY_DATABASE_URL, FIREFLY_SECRET_KEY_BASE... as for one node
          readinessProbe:
            httpGet: {path: /ready, port: http}
```

With a NetworkPolicy, allow ingress on 4369 and 9100 from pods labelled
`app: firefly`. With Docker on several hosts, publish 4369 and 9100 on a
private interface and set `FIREFLY_NODE_HOST` to that address. With
`docker compose up --scale`, the defaults work: each container's own
address on the compose network is its node host. IPv6-only networks also
need `ELIXIR_ERL_OPTIONS="-proto_dist inet6_tcp"`.

### Monitoring

Two unauthenticated JSON endpoints answer probes. They are handled at the
top of the endpoint, before sessions, CSRF, analytics, rate limits, the
locale and theme, and aren't logged per request:

| Endpoint | Answers |
| --- | --- |
| `GET /health` | Liveness: `200 {"status": "ok"}` while the VM runs and serves HTTP. No database call, so a database outage doesn't get every node restarted |
| `GET /ready` | Readiness: `200` when the node should get traffic, else `503` with `"failing"` naming the failed checks. Checks: the database answers `SELECT 1` within 2 seconds, no migration is pending, and the node isn't shutting down (draining). Read-only mode, whether the plugin sandbox is available and how many other cluster nodes this one is connected to are reported in `"checks"` but never fail it |

```json
{"status": "unavailable", "failing": ["migrations"],
 "checks": {"database": {"ok": true}, "migrations": {"ok": false, "pending": [20261101000000]},
            "draining": {"ok": true}, "read_only": {"ok": true, "enabled": false},
            "plugin_sandbox": {"ok": true, "available": true},
            "cluster": {"ok": true, "enabled": false, "nodes": 0}}}
```

Production redirects HTTP to HTTPS (`force_ssl`), except for these two paths,
so a kubelet or load balancer can probe a pod's port over plain HTTP from
inside the cluster; no `Host` header check applies to them. On `SIGTERM`
the node flags itself as draining (`/ready` answers `503`), waits
`FIREFLY_DRAIN_DELAY_MS`, then stops accepting connections. A Kubernetes
example:

```yaml
livenessProbe:
  httpGet: {path: /health, port: 4000}
  periodSeconds: 10
readinessProbe:
  httpGet: {path: /ready, port: 4000}
  periodSeconds: 5
  failureThreshold: 2
```

### Background jobs

Background and scheduled work runs on [Oban](https://hexdocs.pm/oban),
with its jobs in the `oban_jobs` table of Firefly's own PostgreSQL
database. The database coordinates every node, with no clustering or
distributed Erlang: nodes take jobs with `FOR UPDATE SKIP LOCKED`, hear of
new ones over `LISTEN/NOTIFY`, and elect one leader through the database
for what must run once per cluster (pruning, scheduled jobs). A job a
crashed node left running is rescued after 30 minutes.

| Queue | Concurrency per node | |
| --- | --- | --- |
| `default` | 10 | anything else |
| `mailers` | 10 | email |
| `notifications` | 10 | notification fan-out |
| `webhooks` | 5 | webhook deliveries (5 attempts: retried after 30 s, 2, 8 and 32 min; each attempt in the webhook's delivery log) |
| `plugins` | 5 | plugin events (the same retries; the circuit breaker still applies) and plugins' scheduled jobs |
| `ai` | 3 | AI work |
| `maintenance` | 2 | scheduled housekeeping |

Set a queue's concurrency on a node with `FIREFLY_JOBS_<QUEUE>` (e.g.
`FIREFLY_JOBS_AI=0` on web nodes that shouldn't run AI work).

Periodic work runs on cron schedules (Oban's cron, inserted by the leader
only, so once per cluster; see `Firefly.Jobs.Periodic`): thread timers,
bookmark reminders and poll closings every minute (timers and reminders
also get a job at their own time, so they fire on time), unused uploads,
link previews, semantic search embeddings and plugins' scheduled jobs every minute, badges and
digests every 15 minutes, trust level reviews, analytics, the embed feed,
chat retention, the email and egress logs, the user directory and
scheduled backups hourly, and the version check daily. A task isn't
queued again while its last run is waiting or running, and nothing runs
while the site is read-only.

Finished jobs (completed, cancelled and discarded) are kept for the
`job_retention_days` site setting (Advanced, Jobs; default 14 days,
`FIREFLY_SETTING_JOB_RETENTION_DAYS` pins it), then pruned by the leader
once a minute; a change applies at the next run, without a restart.

Admins watch and manage jobs at `/staff/jobs`: [Oban
Web](https://github.com/oban-bg/oban_web) (open source, Apache-2.0), with
queues, jobs by state, their errors and retries, and retry, cancel, delete,
pause and scale controls. Access is checked on every request and every
page mount; every action is in the staff log. `/ready` reports whether jobs
run on the node (`"jobs": {"running": true, "leader": false}`) without
failing on it. Metrics: `oban_job_stop_duration_microseconds` and
`oban_job_exception_count` by queue, worker and state,
`oban_job_stop_queue_time_microseconds` by queue and `firefly_jobs_depth`
by queue and state (never job arguments); with OpenTelemetry on, each job
is a span in the trace of the request that enqueued it.

### Email

Firefly sends email with [Swoosh](https://hexdocs.pm/swoosh) through the
adapter `FIREFLY_MAIL_ADAPTER` names; production refuses to start without
one. Development keeps sent mail in memory, readable at
<http://localhost:4000/dev/mailbox>. Every email, whatever the adapter, is
logged at `/staff/emails`, which also sends a test email and shows the
adapter in use and, when sending fails, its error.

| Adapter | Variables |
| --- | --- |
| `smtp` | `FIREFLY_SMTP_RELAY` (required), `FIREFLY_SMTP_PORT` (default 587, or 465 with SSL), `FIREFLY_SMTP_USERNAME`, `FIREFLY_SMTP_PASSWORD`, `FIREFLY_SMTP_TLS` (STARTTLS: `always`, the default, `if_available` or `never`), `FIREFLY_SMTP_SSL` (`true` for implicit TLS, usually port 465), `FIREFLY_SMTP_AUTH` (`always`, `if_available`, the default, or `never`), `FIREFLY_SMTP_RETRIES` (default 2). The relay's certificate is verified against the system's CAs (or `FIREFLY_SMTP_CA_CERT_FILE`) and its name; `FIREFLY_SMTP_VERIFY=false` turns that off |
| `ses` | Amazon SES: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (required), `AWS_SESSION_TOKEN` for temporary credentials, the region in `FIREFLY_SES_REGION`, `AWS_REGION` or `AWS_DEFAULT_REGION`; optional `FIREFLY_SES_CONFIGURATION_SET`. The adapter signs with these static credentials: it doesn't fetch EC2 instance or ECS task role credentials, so give it an IAM user's keys (with `ses:SendRawEmail`) |
| `sendgrid` | `FIREFLY_SENDGRID_API_KEY` |
| `mailgun` | `FIREFLY_MAILGUN_API_KEY`, `FIREFLY_MAILGUN_DOMAIN`; `FIREFLY_MAILGUN_BASE_URL=https://api.eu.mailgun.net/v3` for EU domains |
| `postmark` | `FIREFLY_POSTMARK_API_KEY` (the server token); optional `FIREFLY_POSTMARK_MESSAGE_STREAM` |
| `local` | None: mail is kept in memory (staging, demos) |

`FIREFLY_EMAIL_FROM` sets the sender address. Reply-by-email (notification
replies posting to the thread) comes in through SendGrid Inbound Parse,
whichever adapter sends (see `FIREFLY_REPLY_EMAIL_DOMAIN` and
`FIREFLY_INBOUND_EMAIL_TOKEN` above). Credentials are never logged or shown.

### Metrics

Firefly exports metrics in Prometheus' text format at `/metrics`, off by
default. Turn it on with either:

- `FIREFLY_METRICS_PORT=9568` (preferred): a listener of its own, which
  serves only `/metrics`, so the metrics stay off the public port. Keep it
  inside your network (or bind it with `FIREFLY_METRICS_IP=127.0.0.1` for a
  local agent).
- `FIREFLY_METRICS_TOKEN=<secret>`: `/metrics` on the main port too, for
  requests with `Authorization: Bearer <secret>`. With a port as well, the
  token is required there too.

What's exported (durations are histograms in microseconds, named
`..._microseconds`; buckets from 0.5 ms to 10 s):

| Metric | Labels |
| --- | --- |
| `vm_memory_{total,processes,binary,ets}`, `vm_total_run_queue_lengths_{total,cpu,io}`, `vm_system_counts_{process,port}_count` | |
| `phoenix_router_dispatch_stop_duration_microseconds`, `phoenix_router_dispatch_exception_count` | `route` (the pattern, e.g. `/categories/:category_id/threads/:id`), `method`, `status` |
| `phoenix_live_view_mount_stop_duration_microseconds`, `phoenix_live_view_handle_event_stop_duration_microseconds`, `phoenix_live_view_handle_event_exception_count` | `view` (event names are left out: clients choose them) |
| `firefly_repo_query_total_time_microseconds`, `firefly_repo_query_queue_time_microseconds` | `source` (table) |
| `firefly_notifications_dispatch_stop_duration_microseconds`, `firefly_notifications_dispatch_exception_count` | `event` (`post_created`, `message_created`...) |
| `firefly_notifications_created_count` | `kind` |
| `firefly_plugins_hook_count`, `firefly_plugins_hook_duration_microseconds` | `plugin`, `hook`, `result`; `hook` |
| `firefly_plugins_event_stop_count`, `firefly_plugins_event_exception_count` | `result` (`delivered`, `failed`, `dropped`) |
| `firefly_queue_depth` | `queue` (`plugin_events`, `webhooks`) |
| `firefly_webhooks_delivery_stop_duration_microseconds`, `firefly_webhooks_delivery_exception_count` | `type`, `result` (`success`, `failure`) |
| `firefly_scheduler_job_stop_duration_microseconds`, `firefly_scheduler_job_exception_count` | `job` |
| `firefly_mailer_deliver_stop_count`, `firefly_mailer_deliver_stop_duration_microseconds`, `firefly_mailer_deliver_exception_count` | `adapter` (`smtp`, `ses`, `sendgrid`, `mailgun`, `postmark`, `local`), `result` (`sent`, `failed`, `skipped`) |
| `firefly_cluster_node_count`, `firefly_cluster_nodes_connected` | `event` (`up`, `down`) on the count |

Every series also has a `node` label, the node it was measured on
(`firefly@10.0.0.7`; one per node), so a cluster's series stay apart. No
label carries a user id or a request path. The VM and queue gauges are
measured every 10 seconds. The domain emits its events with `:telemetry`
(listed in `Firefly.Telemetry`); `FireflyWeb.Telemetry` defines the metrics.
A Prometheus scrape config:

```yaml
scrape_configs:
  - job_name: firefly
    scrape_interval: 15s
    static_configs:
      - targets: ["firefly:9568"]
    # With FIREFLY_METRICS_TOKEN (needed on the main port, optional on the metrics port):
    # authorization:
    #   credentials: <secret>
```

### Observability

Firefly exports OpenTelemetry traces, and optionally metrics and logs, over
OTLP to a collector (the OpenTelemetry Collector, Grafana Alloy, a vendor's
endpoint). Nothing is exported unless an endpoint is set; everything is
configured with the standard variables, which the SDK reads itself:

| Variable | |
| --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | The collector, e.g. `http://otel-collector:4318`; per signal: `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `_METRICS_ENDPOINT`, `_LOGS_ENDPOINT` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` (default) or `grpc` (port 4317) |
| `OTEL_EXPORTER_OTLP_HEADERS` | e.g. an API key: `x-api-key=...` |
| `OTEL_SERVICE_NAME` | Default `firefly` (the release's name) |
| `OTEL_RESOURCE_ATTRIBUTES` | e.g. `deployment.environment=production,service.instance.id=web-1` |
| `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG` | e.g. `parentbased_traceidratio` and `0.1` to keep a tenth of traces |
| `OTEL_TRACES_EXPORTER` | `none` turns traces off even with an endpoint |
| `FIREFLY_OTEL_METRICS`, `FIREFLY_OTEL_LOGS` | `true` to also export metrics and logs (experimental, below); `OTEL_METRIC_EXPORT_INTERVAL` (ms, default 60000) |

What's exported:

- **Traces** (stable SDK: `opentelemetry` 1.7, `opentelemetry_exporter`
  1.11): a server span per request (Bandit), with Phoenix's route and
  LiveView mounts and events, Ecto queries, the AI client's HTTP requests
  (Req) as child spans, and spans for the domain's operations: post
  creation, notification fan-out, email sends (with the adapter and
  template), plugin hook runs and event deliveries, webhook deliveries,
  scheduler jobs and AI requests (see
  `Firefly.Telemetry`). Background jobs (Oban: the notification fan-out,
  emails, pushes, AI and Akismet work...) carry the trace on. Outgoing requests don't send trace headers to third
  parties.
- **Metrics** (`FIREFLY_OTEL_METRICS=true`, **experimental**): the same
  metrics as Prometheus (see "Metrics" above), as OTLP counters, histograms
  (same buckets) and gauges.
- **Logs** (`FIREFLY_OTEL_LOGS=true`, **experimental**): log events at
  `info` and up, with the trace and span ids of the span they were logged in.
  Console logs print `otel_trace_id` and `otel_span_id` too.

OpenTelemetry metrics and logs are still experimental in the Erlang SDK
(`opentelemetry_experimental` and `opentelemetry_api_experimental` 0.6.0,
pinned exactly): their APIs may change between releases, hence the opt-in.

A local stack to try it with, as a `docker-compose.override.yml` next to
Firefly (the collector sends traces to Jaeger, metrics to Prometheus; Tempo
or Loki slot in the same way):

```yaml
services:
  firefly:
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318
      OTEL_RESOURCE_ATTRIBUTES: deployment.environment=local
      FIREFLY_OTEL_METRICS: "true"
      FIREFLY_OTEL_LOGS: "true"
      FIREFLY_METRICS_PORT: "9568"   # Prometheus can also scrape Firefly directly

  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.139.0
    command: ["--config=/etc/otelcol/config.yaml"]
    volumes:
      - ./otelcol.yaml:/etc/otelcol/config.yaml:ro

  jaeger:
    image: jaegertracing/jaeger:2.11.0
    ports: ["16686:16686"]   # the UI

  prometheus:
    image: prom/prometheus:v3.7.3
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--web.enable-otlp-receiver"]
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports: ["9090:9090"]
```

`otelcol.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      http: {endpoint: 0.0.0.0:4318}
      grpc: {endpoint: 0.0.0.0:4317}
processors:
  batch: {}
exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
    tls: {insecure: true}
  otlphttp/prometheus:
    endpoint: http://prometheus:9090/api/v1/otlp
  debug: {}   # logs: swap in Loki, Elasticsearch or a vendor
service:
  pipelines:
    traces: {receivers: [otlp], processors: [batch], exporters: [otlp/jaeger]}
    metrics: {receivers: [otlp], processors: [batch], exporters: [otlphttp/prometheus]}
    logs: {receivers: [otlp], processors: [batch], exporters: [debug]}
```

`prometheus.yml` (OTLP metrics arrive by push; the scrape job reads
Firefly's own `/metrics` instead, if you prefer pull):

```yaml
scrape_configs:
  - job_name: firefly
    static_configs:
      - targets: ["firefly:9568"]
```

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
- **Themes** (`/staff/themes`): themes and theme components with light
  and dark color schemes (daisyUI tokens, with a warning for any text
  color below WCAG AA), custom CSS (up to 100 KB), head, header and footer
  HTML (cleaned of scripts unless an admin allows them; allowed scripts
  get the page's CSP nonce), and image and font assets. Admins preview a
  theme in their own session before making it the default, and can let
  members pick among some (Settings, Interface). Each theme compiles to a
  stylesheet at a versioned URL browsers cache for good. Themes are
  installed as packages (see Packages below) and export as one.
- **Screening** (`/staff/screening`): email addresses or patterns, IP
  addresses or ranges and URL domains that are blocked from signing up or
  posting. Each block is counted and recorded in the staff log.

Every admin action is recorded in the staff log (`/staff/log`).

#### Database admin (optional)

For power admins, a secondary raw-records view
([Kaffy](https://github.com/aesmail/kaffy)) at `/staff/db`. It's off by
default: an admin turns on **Raw database admin**
(`enable_database_admin`, under Site settings > Advanced), and until then
`/staff/db` is a 404. Once on, it's for admins only (moderators and
members are refused, checked on every request) and appears in the
`/staff` sidebar under **Advanced > Database**. It lists and edits users,
categories, threads and posts, tags and tag groups, groups and their
members, badges and themes, and shows the stored site settings, installed
plugins and the email log read-only. Secrets are never shown: password
hashes, plugins' bundles, code, secrets and settings, secret site
settings; API keys and two-factor secrets aren't listed at all.

`/staff` stays the way to run the site: edits in `/staff/db` change rows
directly and skip the forum's own validation and side effects (a banner
on every page says so). Every create, update and delete there is recorded
in the staff log. It follows the site's light/dark choice and its active
theme's colors.

### Sessions

Logins are server-side sessions (`Firefly.Accounts.UserSessions`): the
session cookie holds only a random token, stored hashed with the browser's
device label, address and last activity, and checked on every request and
LiveView mount. Members see their devices under Settings > Security and sign
any out, or all the others; that disconnects its open pages at once. A
password reset or a suspension signs out every session, and staff can sign a
member out everywhere from the user admin (staff-logged). A session ends
after `session_idle_hours` without use (default a week); "Keep me logged in"
(on by default) keeps it across browser restarts for `session_remember_days`
(default 30), the longest any session lasts.

### Banning (fail2ban)

Addresses that keep failing are banned for a while: every page answers them
with a short 403 (`Retry-After` set), before the session or anything else
runs. Health checks and metrics are answered before that check.

What counts, by *jail* (each with its own points threshold, find-time window
and first ban length, in Settings > Security > Banning):

| Jail | Signals |
| --- | --- |
| `auth` | failed password, two-factor and passkey logins, invalid magic links, bad API keys |
| `rate_limit` | any request refused by a rate limit |
| `probe` | 404s (1 point), exploit scanners' paths like `/wp-login.php`, `/.env`, `/.git/` or `*.php` (10 points, answered 404 at once) |
| `csrf` | CSRF failures, invalid or expired confirmation, reset and unsubscribe links |
| `spam` | Akismet spam verdicts, watched-word blocks, screening hits |
| `signature` | inbound-email webhook token and plugin endpoint secret failures |
| `bot` | failed bot challenges |
| `plugin` | what plugins report (`jail.signal`, see PLUGINS.md) |

Each further ban of the same address lasts `jail_bantime_factor` times
longer (2 by default), up to `jail_max_ban_hours` (a week). IPv6 addresses
are banned by their /64 unless `jail_ipv6_prefix` says single addresses.
The `jail_allowlist` setting's addresses and ranges and the trusted proxies
(`FIREFLY_TRUSTED_PROXIES`) are never banned: set the latter behind a
proxy, or the jail sees only the proxy. Admins see the bans in force and the
addresses closest to one at `/staff/security`, and ban or unban addresses
and ranges there (staff-logged). Every ban is in the security log.

Points are counted in memory on each node; bans are stored in the database
(they survive restarts) and shared by every node in a cluster. Ended bans
are forgotten after `ip_retention_days`. Prometheus has
`firefly_security_signal_count` (by jail and kind) and
`firefly_security_ban_count` (by jail and source), never with addresses.

### Security log and IP retention

The security log (`Firefly.Security`) records logins and failed attempts
(password, two-factor, passkey, API), two-factor, passkey and password
changes, API keys (created, first used from each address, revoked),
suspensions and silences, IP bans and quarantined uploads, with the client's IP
address and browser. Members see their own under Settings > Security; admins
see everyone's at `/staff/security`, filtered by event, username or address.

Full IP addresses are kept for the `ip_retention_days` setting (Security >
Security log, default 90). An hourly job then cuts them to their network
(/24 for IPv4, /48 for IPv6) in the security log, API keys' last use and
Akismet checks, and deletes members' address records (`user_ips`), which are
only useful whole. Analytics never store addresses (visitors are a salted
hash); the Akismet check jobs carry the address until the job history is
pruned (`job_retention_days`).

### Plugins

Core plugins are written in Elixir; third-party JavaScript plugins run
sandboxed in QuickJS on WebAssembly and are installed as packages (below).
See [PLUGINS.md](PLUGINS.md) for the plugin API.

### Packages

Plugins and themes ship the same way: a package, a versioned `.zip` with
one manifest (`firefly.json`, extending the plugin manifest) carrying
plugin code, a `theme` section (colors per scheme, CSS, head/header/footer
HTML, assets and the components it includes), or both, plus typed
settings, tags and dependencies. A package with a theme carries the
`theme` tag. Admins install, upgrade and uninstall every package at
`/staff/packages`, one list filtered by tag: upload one, or fetch it from
a URL or a GitHub repository (the repository is the package; fetched from
public addresses only). The list is per site; there is no outside catalog.

Installing checks the manifest, the size limits, the version (an upgrade
must be newer) and the dependencies across every package, and is
staff-logged. A theme package creates or updates its themes, linked to
the package: upgrading one an admin edited since asks before replacing
the edits, and themes from packages never run scripts. A package that is
only a theme needs no plugin sandbox. `/staff/themes` stays the theme
editor and picker; an admin's own theme exports as a package, and old
theme JSON bundles still install. See `Firefly.Packages` for the format.

A plugin's package may also ship theme components (colors and CSS that
themes include; HTML cleaned, never scripts), which installing needs a
separate, staff-logged grant for. Running scripts stays an admin's choice
on their own themes; no package can ask for it. A theme package's typed
settings (the plugin settings schema) are edited on its theme's page and
reach its CSS as custom properties, `--<package id>-<key>`.

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
`FIREFLY_PW_TRACE=true` to record Playwright traces. The test server
listens on `FIREFLY_TEST_PORT` (default 4002); with a different port and
`MIX_TEST_PARTITION` (its own database), two suites can run side by side.

The clustering test starts a second node (`:peer`) and has both find each
other through the test database, so it needs `epmd` (it starts it) and is
left out unless included (CI runs it):

```sh
(cd apps/firefly && mix test --only cluster)
```

Property-based and fuzz tests ([StreamData](https://hexdocs.pm/stream_data),
in each app's `test/property`) check invariants over generated input: valid
domain data and adversarial input (unicode and control characters, nested
markup, script URLs, path traversal, huge numbers), from the shared
generators in `Firefly.Generators`. Each property runs a few dozen cases in
a plain `mix test` (`FIREFLY_PROPERTY_RUNS` raises that); the deep runs are
tagged `:fuzz` and left out unless asked for:

```sh
mix test --only fuzz                          # deep fuzzing, 5000 cases per property
FIREFLY_FUZZ_RUNS=50000 mix test --only fuzz  # deeper
```

A failing property prints the smallest input it found; that input goes into
a plain example test next to the fix.

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

### Security checks

CI's Security job fails on any of these; the Docker image job also scans the
built image with [Trivy](https://trivy.dev) (HIGH and CRITICAL
vulnerabilities that have a fix). Dependabot (`.github/dependabot.yml`)
opens weekly updates for Hex, npm and GitHub Actions.

```sh
mix deps.audit                        # advisories against mix.lock (mix hex.audit: retired releases)
ln -s ../../config apps/firefly_web/config   # once: Sobelow's config checks look there
mix sobelow --root apps/firefly_web   # and apps/firefly, apps/firefly_plugins, apps/firefly_import
docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/gitleaks/gitleaks:v8.30.1 git --redact .
```

[Sobelow](https://github.com/sobelow/sobelow) reads each app's reviewed
`.sobelow-conf` and fails on a finding of any confidence. A finding that's
a false positive is skipped where it is, with its reason:

```elixir
# Sobelow: the path comes from a signed token whose name is validated.
# sobelow_skip ["Traversal.SendDownload"]
def download(conn, params) do
```

gitleaks' reviewed exceptions (test keys, the old development keys) are in
`.gitleaks.toml`.

## Patrons

Firestorm was funded by [a
Kickstarter](https://www.kickstarter.com/projects/1003377429/firestorm-an-open-source-forum-in-phoenix-from-eli).

All of the patrons that made it possible are listed in [the PATRONS file](PATRONS.md).


## License

Firefly is licensed under the [Apache License 2.0](./LICENSE), © [tznc.dev](https://tznc.dev).
It contains code from Firestorm, originally MIT licensed; see [NOTICE](./NOTICE).
