# Security

How Firefly protects accounts, logins and uploads, how CI checks it, and what
to know before deploying. Settings named here are site settings, most under
Settings > Security; environment variables are listed in the README's
"Production configuration".

## Sessions

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

## Passwords and logins

New passwords (sign-up, invitations, resets) must score at least
`min_password_score` (default 2 of 4) by
[zxcvbn](https://github.com/techgaun/zxcvbn-elixir), which knows common
passwords, names and the member's own username and email; the forms show the
score as members type. With `check_breached_passwords` (on by default) they're
also checked against Have I Been Pwned's [Pwned
Passwords](https://haveibeenpwned.com/Passwords) by k-anonymity: only the
first 5 hex characters of the password's SHA-1 leave the server (through the
same guarded client as link previews, 3 second limit), and if the service
can't be reached the password is accepted and a warning logged.

Members are emailed when their account is logged into from a browser and
network (/24 or /48) it hasn't used before; they can turn that off in their
notification settings. Password logins slow down after repeated failures:
nothing for 3, then 250 ms doubling with each, up to 5 seconds, counted per
account and per address (the jail's `auth` points), whichever is more.

## Bot challenge

Sign-up (including invitations), password reset and login link requests ask
for a bot challenge, and so do password logins after
`bot_challenge_login_failures` (default 3) recent failures of the account or
the address. Nobody solves a puzzle. The browser answers in the background
while a status line (a polite live region) says it's checking. Pick it in
Security > Bot challenge:

- **Proof of work** (default, self-hosted): ALTCHA's scheme
  ([altcha](https://hex.pm/packages/altcha)). The server signs a challenge
  with a key derived from the secret key base, good for 20 minutes. The
  browser looks for a secret number below `bot_challenge_difficulty`
  (default 100,000: about a second on a phone). The server checks the
  signature, the answer and the expiry, and accepts each challenge once,
  per node. Nothing leaves the site. It needs a secure context (see
  "Notes" below).
- **Cloudflare Turnstile** or **hCaptcha**: set the site key and secret
  key. Answers are checked with the provider's `siteverify`, and a check
  that can't reach it fails. The pages' Content-Security-Policy allows
  the provider's script.
- **Off**.

Each failed answer is a `bot_challenge` signal for the jail's `bot` jail. The
JSON API's login isn't challenged: login delays and the jail cover it.

## Banning (fail2ban)

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

## Security log and IP retention

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

## Uploads

The type comes from the file's content, and a file whose name or claimed
type says otherwise is refused. SVG images are rendered to PNGs (so no
script, `foreignObject`, event handler or external reference survives); other
files than images are served as downloads (`Content-Disposition: attachment`),
everything with `X-Content-Type-Options: nosniff` and a sandboxing CSP. With
`FIREFLY_CLAMAV_HOST` set, a new upload is served to no one until clamd has
scanned it (a background job, retried while clamd is unreachable); an infected
file is quarantined, recorded in the staff log and refused from then on.

## Security checks

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

## Notes

- **Secure context.** The proof-of-work bot challenge uses WebCrypto, which
  browsers offer only in a secure context (HTTPS or localhost). Plain-HTTP dev
  on a LAN address (`http://192.168.x.x:4000`) can't answer it: use
  localhost, a tunnel to it, or TLS.
- **`altcha` 2.2.0 workarounds**, both in `Firefly.Security.Challenge`: the
  package's own expiry check has no effect, so the expiry is checked there;
  and `Altcha.V1.Payload.from_json/1` turns client-sent keys into atoms, so
  the answer is decoded there with fixed keys instead.
- **Known limits.**
  - The challenge's replay cache is per node: in a cluster an answer could be
    replayed once on each node within its 20 minutes.
  - The JSON API's login has no challenge; login delays and the jail cover it.
  - Upload virus scanning fails closed: while clamd is down, new uploads wait.
- **Old secret.** A 2017 `secret_key_base` from `config/prod.secret.exs` is
  still in git history. Firefly doesn't use it (production reads
  `FIREFLY_SECRET_KEY_BASE`), but any deployment that ever used it should
  rotate its key.
