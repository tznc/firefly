# Firefly plugins

Plugins extend Firefly without forking it. Every plugin implements one Elixir
behaviour, `FirestormWeb.Plugin`, and the host (loading, hook dispatch,
permissions, settings, the staff log, the circuit breaker) only talks to
plugins through it. There are two kinds:

| | Core plugins | Uploaded plugins |
|---|---|---|
| Written in | Elixir (or Elixir wrapping a Rust NIF) | JavaScript |
| Runs | natively, in the BEAM | sandboxed: QuickJS compiled to WebAssembly, on wasmtime (Wasmex) |
| Installed by | listing the module in config | staff uploading a `.zip` at `/staff/plugins` |
| Trust | trusted; permissions granted without a prompt | staff see the requested permissions before installing |
| Implementation | the module itself (`use FirestormWeb.Plugin`) | `FirestormWeb.Plugin.Sandboxed`, one module serving every bundle |

Both kinds appear at `/staff/plugins`, can be enabled and disabled, have
settings, statistics and an error log, can depend on each other, and are
subject to the same time limits, permission checks and circuit breaker.

There is no plugin registry yet. The manifest's `source` (`"upload"` or
`"core"`) and the reserved `registry` key leave room for Firefly Cloud's.

## Core plugins

```elixir
defmodule MyApp.Greeter do
  use FirestormWeb.Plugin,
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
config :firestorm_web, FirestormWeb.Plugins, core: [MyApp.Greeter]
```

The keyword list is the manifest. Which hooks the plugin implements is
worked out from the callbacks it defines. Core plugins are enabled unless
staff disable them, and can't be uninstalled. A NIF-backed plugin is an
ordinary Elixir module that calls its NIF from its callbacks; nothing in
the behaviour assumes pure Elixir. Host functions are at
`FirestormWeb.Plugin.Host.call(plugin, name, args)`, with the same
permission checks as for sandboxed plugins.

## Uploaded plugins

A `.zip` (at most 1 MB, 100 files, 5 MB unpacked) with `plugin.json` at its
root (or in one top-level folder) and the plugin's JavaScript:

```
plugin.json
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

| Limit | Default | Config (`FirestormWeb.Plugin.Sandboxed`) |
|---|---|---|
| Memory | 32 MB | `memory:` |
| CPU | 400M wasmtime fuel units (about 100 ms) | `fuel:` |
| Wall clock | the hook's time limit (2 s unless the hook sets less) | `FirestormWeb.Plugin.Runner, timeout:` |
| Result size | 1 MB | `max_output:` |

Every failure is a structured error (`timeout`, `memory`, `trap`,
`js_error`, `no_handler`, `bad_output`, `output_too_large`; `crash` for a
core plugin that raises) recorded in the plugin's error log. Five failures
in a row (`FirestormWeb.Plugins, breaker_threshold:`) turn the plugin off
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
`FirestormWeb.Plugins.Content, timeout:`) is skipped and its step keeps its
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
| `kv.get` / `kv.set` / `kv.delete` / `kv.list` | | `{key}` / `{key, value}` / `{key}` / `{prefix}` | value / `null` / `null` / keys |
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
`{id, title, category_id, url}`. Events are queued in the database in the
same transaction as the change and delivered by `FirestormWeb.Plugins.Queue`
(within about a second): a failure is retried after 30 s, 2, 8 and 32
minutes, then dropped and logged. Only content anonymous visitors can read
produces events, and a plugin never hears about its own bot's actions.

## Scheduled jobs

`jobs` entries are `{"name", "every": seconds}` (60 or more) or
`{"name", "cron": "m h dom mon dow"}` (UTC). Due jobs call `run_job` with
`{job}`; the next run time is stored, so jobs survive restarts and run once
across nodes. A failed run isn't retried before its next time.

## Storage and custom fields

Each plugin has a key-value store (any JSON values; 1,000 keys and 1 MB by
default, `FirestormWeb.Plugins.Storage, max_keys:, max_bytes:`). Custom
fields are values a plugin keeps on posts, threads or users, namespaced by
plugin, limited to the keys its manifest declares; `public` post fields
appear in the JSON API as `plugin_fields: {plugin_id: {key: value}}`.

Uninstalling a plugin (after a confirm step) deletes its bundle, settings,
error log, storage, custom fields, queued events and job schedule; its bot
user stays with its posts.

## The WebAssembly runtime

`priv/plugins/quickjs.wasm` is QuickJS-ng (pinned commit) plus
`wasm/quickjs/firefly_runtime.c`, built as a WASI reactor with Debian's
clang and wasi-libc. `wasm/quickjs/build.sh` rebuilds it in Docker,
reproducibly; the runtime refuses to load a `.wasm` that doesn't match the
committed `quickjs.wasm.sha256`, and a test checks it.
