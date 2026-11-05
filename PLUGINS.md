# Firefly plugins

Plugins extend Firefly without forking it. Every plugin implements one Elixir
behaviour, `Firefly.Plugin`, and the host (loading, hook dispatch,
permissions, settings, the staff log, the circuit breaker) only talks to
plugins through it. There are two kinds:

| | Core plugins | Uploaded plugins |
|---|---|---|
| Written in | Elixir (or Elixir wrapping a Rust NIF) | JavaScript |
| Runs | natively, in the BEAM | sandboxed: QuickJS compiled to WebAssembly, on wasmtime (Wasmex) |
| Installed by | listing the module in config | staff installing its package at `/staff/packages` (an upload, a URL or a GitHub repository) |
| Trust | trusted; permissions granted without a prompt | staff see the requested permissions before installing |
| Implementation | the module itself (`use Firefly.Plugin`) | `FireflyPlugins.Sandboxed`, one module serving every bundle |

Both kinds appear at `/staff/plugins`, can be enabled and disabled, have
settings, statistics and an error log, can depend on each other, and are
subject to the same time limits, permission checks and circuit breaker.

Uploaded plugins ship as packages (see "Uploaded plugins" below and
"Packages" in the README): admins install, upgrade and uninstall them at
`/staff/packages`, uploaded or fetched from a URL or a GitHub repository,
with versions and dependencies checked across every package. The list is
per site; there is no shared catalog yet. The manifest's `source`
(`"upload"` or `"core"`) and the reserved `registry` key leave room for
Firefly Cloud's.

## Core plugins

```elixir
defmodule MyApp.Greeter do
  use Firefly.Plugin,
    id: "greeter",
    name: "Greeter",
    version: "1.0.0",
    firefly: "~> 1.0",
    description: "Says hello.",
    author: "Me",
    exports: ["greet"],
    settings: [%{key: "greeting", type: "string", default: "Hello"}]

  @impl true
  def call_export(plugin, "greet", %{"name" => name}),
    do: {:ok, "#{plugin.settings["greeting"]}, #{name}"}
end
```

```elixir
config :firefly, Firefly.Plugins, core: [MyApp.Greeter]
```

The keyword list is the manifest. Which hooks the plugin implements is
worked out from the callbacks it defines. Core plugins are enabled unless
staff disable them, and can't be uninstalled. A NIF-backed plugin is an
ordinary Elixir module that calls its NIF from its callbacks; nothing in
the behaviour assumes pure Elixir. Host functions are at
`Firefly.Plugin.Host.call(plugin, name, args)`, with the same
permission checks as for sandboxed plugins.

## Uploaded plugins

Uploaded plugins are packages (see "Packages" in the README and
`Firefly.Packages`): a `.zip` (at most 5 MB, 200 files, 20 MB unpacked)
with `firefly.json` (or, as before, `plugin.json`) at its root (or in one
top-level folder) and the plugin's JavaScript. The manifest may carry
`tags`, shown and filtered on at `/staff/packages`. A plugin depends only
on plugins.

```
firefly.json
index.js
lib/util.js
```

```js
// index.js: CommonJS modules, relative requires only.
const util = require("./lib/util");

exports.enabled = () => firefly.log("hello from", firefly.plugin.id);
exports.greet = ({ name }) => `${firefly.plugin.settings.greeting}, ${name}`;
```

Each hook calls the exported handler of the same name with one argument,
the hook's input, and its return value (or the value of a returned promise)
is the result. Inside the sandbox:

- `firefly.plugin`: `{id, version, settings}`.
- `firefly.call(name, args)`: a host function (below); throws on errors.
- `firefly.log(...)`, `console.log/info/warn/error`: to the server log.
- Standard JavaScript built-ins. No filesystem, network, process,
  environment, timers or module imports; `Date` reads the host's time at the
  start of the call, fixed for its duration.

### Sandbox limits

Every call gets a fresh WebAssembly instance, discarded afterwards:

| Limit | Default | Config (`FireflyPlugins.Sandboxed`) |
|---|---|---|
| Memory | 32 MB | `memory:` |
| CPU | 400M wasmtime fuel units (about 100 ms) | `fuel:` |
| Wall clock | the hook's time limit (2 s unless the hook sets less) | `Firefly.Plugin.Runner, timeout:` |
| Result size | 1 MB | `max_output:` |

Every failure is a structured error (`timeout`, `memory`, `trap`,
`js_error`, `no_handler`, `bad_output`, `output_too_large`; `crash` for a
core plugin that raises) recorded in the plugin's error log. Five failures
in a row (`Firefly.Plugins, breaker_threshold:`) turn the plugin off
and notify admins; plugins that need it are suspended until it's enabled
again.

## Manifest

```json
{
  "id": "hello",
  "name": "Hello",
  "version": "1.2.0",
  "firefly": "~> 1.0",
  "description": "Says hello.",
  "author": "Jane",
  "url": "https://example.com",
  "license": "MIT",
  "main": "index.js",
  "hooks": ["enabled"],
  "permissions": ["read"],
  "settings": [
    {"key": "greeting", "type": "string", "default": "Hi", "label": "Greeting", "help": "What to say."}
  ],
  "assets": [],
  "dependencies": {"other": "~> 1.2"},
  "optional_dependencies": {"extra": ">= 0.3.0"},
  "exports": ["greet"],
  "shortcodes": ["spoiler"],
  "events": ["post_created"],
  "jobs": [{"name": "digest", "every": 3600}, {"name": "nightly", "cron": "30 2 * * *"}],
  "http_hosts": ["api.example.com", "*.example.org"],
  "fields": [{"type": "post", "key": "score", "public": true}],
  "widgets": [{"outlet": "post_footer", "asset": "widget.html", "height": 80}],
  "endpoint_auth": "secret",
  "composer_buttons": [{"label": "Spoiler", "insert": "[spoiler]{{selection}}[/spoiler]"}],
  "priority": 100,
  "source": "upload"
}
```

Validation is strict: unknown keys, hooks or permissions are errors.
`firefly` must match the plugin API version (`1.0.0`). Setting types:
`string`, `text`, `integer` (`min`, `max`), `boolean`, `enum` (`choices`);
every setting needs a valid `default`. Staff edit settings at
`/staff/plugins/:id`, in a form generated from these definitions.

## Dependencies

`dependencies` and `optional_dependencies` map plugin ids to `Version`
requirements; core and uploaded plugins can depend on each other.

- Installing or upgrading is refused, saying what's wrong, if any plugin
  would be left with a missing or incompatible dependency, or the graph
  would have a cycle (named, e.g. `a → b → a`).
- Plugins load and their hooks run in dependency order; `priority` (lower
  first, default 100) breaks ties, then the id.
- A plugin is active when it's enabled, has no problems, and its required
  dependencies are active.
- Enabling a plugin enables the disabled plugins it needs; disabling one
  disables the enabled plugins that need it. Both are confirmed first,
  listing the cascade. Uninstalling a plugin others need is refused.
- A plugin may call another's `exports` through the `plugins.call` host
  function, only if it depends on it.

## Hooks

| Hook | Callback | Input | Result |
|---|---|---|---|
| `enabled` | `enabled(plugin)` | `{}` | ignored |
| `disabled` | `disabled(plugin)` | `{}` | ignored |
| (exports) | `call_export(plugin, function, args)` | `args` | the function's result |
| `render_shortcodes` | `render_shortcodes(plugin, input)` | `{shortcodes: [{name, attrs, content}], post}` | one HTML string per shortcode |
| `render_post` | `render_post(plugin, input)` | `{html, post}` | the new HTML |
| `handle_event` | `handle_event(plugin, input)` | `{event, data}` | ignored; a failure is retried |
| `run_job` | `run_job(plugin, input)` | `{job}` | ignored |
| `moderate_post` | `moderate_post(plugin, input)` | `{kind, title, body, user, thread, category_id}` | `{action: "allow"}`, `{action: "queue", reason}` or `{action: "reject", message}` |
| `flag_created` | `flag_created(plugin, input)` | `{post, thread, flag: {reason, note}}` | `{action: "none"}` or `{action: "hide"}` |
| `handle_widget` | `handle_widget(plugin, input)` | `{handler, args, context, user}` | anything, back to the widget |
| `render_page` | `render_page(plugin, input)` | `{path, params, user}` | `{title, html}` or `{title, iframe: asset}` |
| `render_admin` | `render_admin(plugin, input)` | `{user}` | as `render_page` |
| `handle_request` | `handle_request(plugin, input)` | `{method, path, query, body, user}` | `{status, body}` (JSON) |

Core plugins can also implement `asset(plugin, path)` to serve the files
their widgets and pages use (uploaded bundles serve their `assets`).

`post` is `{id, thread_id, category_id, user_id}`.

## Content

A post's body is rendered from markdown and sanitized, then:

1. **Shortcodes**: `[name attr="value"]content[/name]` or `[name attr=value]`
   for names in a plugin's `shortcodes` (the first plugin in hook order
   owns a name). Not inside code. `content` is the rendered HTML between
   the tags; each plugin gets all its shortcodes in a post in one call.
2. **`render_post`** hooks, in order, each given the previous one's HTML.

The result goes through the markdown sanitizer's allow-list again, so
plugins can't add scripts, event handlers, `javascript:` URLs or iframes
(and `class` survives only where markdown allows it, e.g. `span`, `div`,
`code`). A plugin that fails or exceeds the render time limit (500 ms,
`Firefly.Plugins.Content, timeout:`) is skipped and its step keeps its
input. Only posts anonymous visitors can read are transformed; posts in
private categories, and deleted, hidden or queued posts, never reach
plugins. Results are cached per node (10,000 entries, LRU), keyed by the
input HTML and a fingerprint of the active content plugins' ids, versions,
code and settings, so enabling, disabling, upgrading or reconfiguring a
plugin takes effect at once. The editor preview, emails, private messages
and the JSON API show the markdown rendering without plugin transforms.

`composer_buttons` add buttons above the post editor that insert their
`insert` text at the caret, with `{{selection}}` replaced by the selected
text. They're data, not code: nothing runs in the browser.

## Host functions

| Function | Permission | Arguments | Result |
|---|---|---|---|
| `log` | | `{level, message}` | `null` |
| `settings` | | | the plugin's settings |
| `site` | | | `{title, url, api_version}` |
| `plugins.call` | (a dependency) | `{plugin, function, args}` | the function's result |
| `posts.get` | `read` | `{id}` | a public post |
| `threads.get` | `read` | `{id}` | a public thread |
| `users.get` | `read` | `{id}` or `{username}` | a public profile |
| `kv.get` / `kv.set` / `kv.delete` / `kv.list` | | `{key}` / `{key, value}` / `{key}` / `{prefix}`, each with an optional `user_id` | value / `null` / `null` / keys |
| `tags.add` / `tags.remove` | `tags` | `{thread_id, tag}` | the thread's tags |
| `posts.reply` | `post` | `{thread_id, body}` | `{id}` |
| `posts.flag` | `flag` | `{post_id, reason, note}` | `{id}` |
| `notifications.send` | `notify` | `{user_id}` or `{username}`, `{subject, body, path}` | `null` |
| `threads.close` / `threads.pin` | `moderate` | `{thread_id, closed}` / `{thread_id, pinned}` | `null` |
| `http.fetch` | `http` | `{url, method, headers, body}` | `{status, headers, body}` |
| `fields.get` / `fields.set` | `fields` | `{type, id}` / `{type, id, key, value}` | fields / `null` |

Reads see only what an anonymous visitor may: private categories, deleted
and hidden posts stay out of reach. Writes act as the plugin's **bot user**
(`<id>-bot`, created on install, or on first use for core plugins) through
the same contexts and policies as a member's: `Posting.check` (penalties,
closed threads, slow mode, rate limits), tag groups and `tags_admin_only`,
flag rules, and only on public threads. Thread moderation and tagging are
allowed to a bot by explicit policy rules (`:moderate_thread`,
`:tag_thread`) for plugins holding the permission; staff actions by bots are
staff-logged as the bot. Plugin notifications (`kind: "plugin"`) link only
to paths on this site, at most 100 an hour per plugin.

`http.fetch` reaches only the manifest's `http_hosts` (`*.example.com`
for subdomains). The host is resolved by Firefly and every address must be
public (no loopback, private, link-local, CGNAT, multicast, documentation
or reserved ranges, IPv4 or IPv6, including IPv4-mapped); the request goes
to the checked address (TLS still verified against the name), redirects
aren't followed, 5 s timeout, 100 KB request and 1 MB response bodies.

### Network access

`http.fetch` only works where a slow or hostile host can't hold up members'
pages and forum content doesn't leave the site every time it's shown. The
host checks the hook the call runs in (the runner records it for the call's
process), for core and sandboxed plugins alike; elsewhere it fails with
"http.fetch is not available in synchronous hooks (<hook>); use an event or
job", which also goes to the plugin's error log.

| Hook | `http.fetch` |
|---|---|
| `render_shortcodes`, `render_post` | refused: they run while a page renders |
| `moderate_post`, `flag_created` | refused: they run while a member's post or flag is saved |
| `handle_event`, `run_job` | allowed: background work |
| `enabled`, `disabled` | allowed: a staff action, once (e.g. registering a webhook) |
| `handle_widget`, `handle_request` | allowed: the plugin's own widget or endpoint asked for it, and waits |
| `render_page`, `render_admin` | allowed: the plugin's own page, which someone opened; it waits for the plugin (2 s at most), so cache what you can with `kv` |
| exports | as the hook the call chain started in: allowed when a plugin's `handle_event` calls another's export through `plugins.call`, refused from its `render_post`; refused when Elixir code calls an export directly |

A process a core plugin starts itself is outside any hook, so it gets no
network either. To show remote data in posts, fetch it in the background and
render from what you stored:

```js
// On post_created (needs "read" and the "post_created" event), look up
// what the post links to and keep it; render_post only reads it.
exports.handle_event = ({ event, data }) => {
  const res = firefly.call("http.fetch", { url: `https://api.example.com/lookup?post=${data.post.id}` });
  firefly.call("kv.set", { key: `card:${data.post.id}`, value: JSON.parse(res.body) });
};
exports.render_post = ({ html, post }) => {
  const card = firefly.call("kv.get", { key: `card:${post.id}` });
  return card ? html + `<p>${card.title}</p>` : html;
};
```

To check posts with a remote service, decide what you can in
`moderate_post` from what's in hand, queue the rest for staff review, and
ask the service from an event once the post is public:

```js
// Synchronous: no network. Queue what needs a closer look.
exports.moderate_post = ({ body, user }) =>
  /https?:\/\//.test(body) && firefly.call("kv.get", { key: "trusted", user_id: user.id }) !== true
    ? { action: "queue", reason: "links from a member not yet checked" }
    : { action: "allow" };

// In the background, on post_created and post_edited: ask the service and
// put what it flags in front of staff (needs "flag").
exports.handle_event = ({ event, data }) => {
  const res = firefly.call("http.fetch", {
    url: "https://api.example.com/check",
    method: "POST",
    body: JSON.stringify({ text: data.post.body }),
  });
  if (JSON.parse(res.body).spam) {
    firefly.call("posts.flag", { post_id: data.post.id, reason: "spam", note: "api.example.com says spam" });
  } else {
    firefly.call("kv.set", { key: "trusted", value: true, user_id: data.post.user_id });
  }
};
```

Queued posts produce no events until staff approve them, and plugins can't
approve or reject them, so the remote check runs on what's published (a
post staff approved, or one `moderate_post` allowed) and reports through
flags, which staff review and which `flags_to_hide` turns into hiding.
`trusted` is kept in each member's own store (`user_id`), so it's in their
account export and goes with their account.

### Egress log

Every `http.fetch` a plugin attempts is logged, sent or refused (missing
permission, a synchronous hook, a host not in `http_hosts`, a private
address, a bad request): the plugin, method, host, path **without the query
string** (where tokens travel), the status or the kind of error, bytes sent
and received, the duration and the time. Request and response bodies and
headers are never logged. Staff see the latest entries on
`/staff/plugins/:id`, filtered by host and by allowed or blocked. Entries
are kept for the `plugin_egress_days` site setting (14 days by default;
`/staff/settings`, "Plugins") and pruned by an hourly background job;
they stay after a plugin is uninstalled until then. Firefly's own
requests (link previews) aren't plugin traffic and aren't logged here.

### What staff see

Staff see what a plugin may do in plain words before installing it and on
its page: `http` reads "Can send forum content to: api.example.com,
hooks.slack.com" (`*.example.org` as "any subdomain of example.org"), and
each other permission says what it allows ("Can reply in public threads,
as its bot account"). Uploading a newer version that asks for a permission
or host the installed one didn't says so above the list and marks each one
new.

## Events

Subscribe with `events` (needs the `read` permission and the
`handle_event` hook; `flag_raised` also needs `flag`):

| Event | Data |
|---|---|
| `post_created`, `post_edited` | `{post, thread}` |
| `post_deleted` | `{post_id, thread_id}` |
| `thread_created` | `{thread, post}` |
| `user_registered` | `{user: {id, username}}` |
| `flag_raised` | `{post_id, thread_id, reason}` |
| `post_liked` | `{post_id, thread_id, user_id}` |
| `solved` | `{thread_id, post_id}` |
| `poll_closed` | `{poll_id, post_id, thread_id}` |

A post is `{id, thread_id, user_id, author, body, url}`, a thread
`{id, title, category_id, url}`. Each event is a background job (Oban's
`plugins` queue, see "Background jobs" in the README) enqueued in the same
transaction as the change and delivered within moments: a failure is
retried after 30 s, 2, 8 and 32 minutes, then dropped and logged. Only content anonymous visitors can read
produces events, and a plugin never hears about its own bot's actions.

## Scheduled jobs

`jobs` entries are `{"name", "every": seconds}` (60 or more) or
`{"name", "cron": "m h dom mon dow"}` (UTC). Due jobs call `run_job` with
`{job}`; the next run time is stored, so jobs survive restarts and run once
across nodes. Due jobs are checked every minute (a background job on the
`plugins` queue). A failed run isn't retried before its next time.

## Moderation

`moderate_post` (needs `read`) runs synchronously before a new thread,
reply or edited body is saved, for every way of posting (web, API, inbound
email all go through `Firefly.Discussion`), as a changeset validation:

- `reject`: the post isn't saved; the author sees the message as a form
  (or API) error. The first rejection wins.
- `queue`: the post waits in the review queue at `/staff/review`, which
  shows "Plugin <name>: <reason>"; staff approve or reject it as usual.

The time limit is strict (300 ms, `Firefly.Plugins.ModerationHooks,
timeout:`). If a plugin fails or times out, posting goes ahead by default
(fail open); staff can switch a plugin to fail closed on its admin page, so
posts are refused with a "try again" message instead. Admins' posts and
posts in categories anonymous visitors can't read aren't checked.

`flag_created` (needs `flag`) runs when a member flags a public post;
answering `hide` hides it until staff review it, as enough flags would.

## Interface

**Widgets** (manifest `widgets`) show one of the plugin's HTML `assets` in
an outlet: `post_footer`, `thread_header`, `sidebar`, `user_profile` or
`composer`. Each is an `<iframe sandbox="allow-scripts">` (no
`allow-same-origin`: an opaque origin, no access to the page, its cookies
or storage) loading `/plugins/:id/assets/<asset>`, which is served with a
strict CSP (`default-src 'none'`, scripts and styles only from the site
and inline, `connect-src 'none'`, `sandbox allow-scripts`). Widgets about a
post or thread only appear on content anonymous visitors can read.

Widgets talk to the page through `postMessage` only, with the SDK:

```html
<script src="/plugins/sdk.js"></script>
<script>
  Firefly.ready(({user, context, plugin}) => {      // user: {id, username, name} or null
    Firefly.call("view", {}).then((result) => {     // the plugin's handle_widget
      document.body.textContent = JSON.stringify(result);
      Firefly.resize();                             // also automatic on changes
    });
  });
</script>
```

`context` comes from the page (e.g. `{post_id, thread_id}`) and, like
`args`, must be treated as untrusted by the handler. Calls are rate limited
(60 a minute per member or IP). Heights are kept between 20 and 2000 px.

**Viewer storage**: a widget can keep data for the member looking at it,
on the server, in the plugin's per-member store (the one `kv.*` reaches
with `user_id`, same quota):

```js
Firefly.ready(async () => {
  if (!Firefly.isLoggedIn()) return;                // Firefly.user is the viewer or null
  const seen = (await Firefly.storage.get("seen")) || 0;
  await Firefly.storage.set("seen", seen + 1);      // any JSON, at most 8 KB
  await Firefly.storage.list("");                   // keys by prefix; also .delete(key)
});
```

It's always the logged-in viewer's own data: the page relays the request
and the server picks the member, so a widget can't name another
`user_id`. Visitors get an error ("sign in to save data"), so hide what
needs storage when `isLoggedIn()` is false. Writes are limited to 30 a
minute per plugin and member. No permission is needed beyond having a
widget (the plugin's frame apps can use it too); the data is the member's,
in their account export and deleted with their account. There's no
browser-side storage: the frame's opaque origin has none.

**Pages**: `/plugins/:id` and `/plugins/:id/*path` call `render_page`;
`html` is sanitized and shown in the site's layout, `iframe` shows an asset
as a full sandboxed app (same bridge, `context: {path}`). **Staff
sections**: `render_admin` adds the plugin's own section to
`/staff/plugins/:id`.

**Endpoints**: any method to `/api/plugins/:id/*path` calls
`handle_request` and returns its `body` as JSON with its `status`. Callers
authenticate as `endpoint_auth` says: `secret` (header `x-plugin-secret`,
shown on the plugin's staff page, where staff can replace it), `user` (a
member's API token, `Authorization: Bearer`), or `either`. 300 requests a
minute per plugin and client IP; bodies up to 100 KB.

## Example

`apps/firefly_plugins/priv/plugins/examples/hello` uses most hooks: a `[hello name="…"]`
shortcode and a post transform, a composer button, a widget under posts
backed by `handle_widget` that counts each member's views in their own
storage, a page and a frame app, a staff section, an
endpoint (`GET /api/plugins/hello/stats`), events, a scheduled job,
moderation driven by its settings, a flag hook, a public custom field and
an export. Zip the folder and upload it at `/staff/packages`.

## Storage and custom fields

Each plugin has a key-value store (any JSON values; 1,000 keys and 1 MB by
default, `Firefly.Plugins.Storage, max_keys:, max_bytes:`). Custom
fields are values a plugin keeps on posts, threads or users, namespaced by
plugin, limited to the keys its manifest declares; `public` post fields
appear in the JSON API as `plugin_fields: {plugin_id: {key: value}}`.

Passing `user_id` to `kv.*` uses the store the plugin keeps for that
member instead: a separate namespace per (plugin, member), so `score` in
the global store and in two members' stores are three keys. Each has its
own quota (200 keys and 64 KB by default, `user_max_keys:`,
`user_max_bytes:`). Server-side code may pass any existing member's id;
an unknown or deleted one is an error. Member data is the member's: their
entries and the plugin's fields on them (`type: "user"`) are in their
account export, grouped by plugin id, and are deleted with their account.
Fields on their posts and threads stay with the content.

```js
// One counter for the forum, one per member.
const total = (firefly.call("kv.get", { key: "posts" }) || 0) + 1;
firefly.call("kv.set", { key: "posts", value: total });
const mine = (firefly.call("kv.get", { key: "posts", user_id: data.post.user_id }) || 0) + 1;
firefly.call("kv.set", { key: "posts", value: mine, user_id: data.post.user_id });
```

Uninstalling a plugin (after a confirm step) deletes its bundle, settings,
error log, storage (global and every member's), custom fields, queued
events and job schedule; its bot user stays with its posts.

## The WebAssembly runtime

`apps/firefly_plugins/priv/plugins/quickjs.wasm` is QuickJS-ng (pinned commit) plus
`apps/firefly_plugins/wasm/quickjs/firefly_runtime.c`, built as a WASI reactor with Debian's
clang and wasi-libc. `apps/firefly_plugins/wasm/quickjs/build.sh` rebuilds it in Docker,
reproducibly; the runtime refuses to load a `.wasm` that doesn't match the
committed `quickjs.wasm.sha256`, and a test checks it.
