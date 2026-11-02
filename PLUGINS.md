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

Reads see only what an anonymous visitor may: private categories, deleted
and hidden posts stay out of reach.

## The WebAssembly runtime

`priv/plugins/quickjs.wasm` is QuickJS-ng (pinned commit) plus
`wasm/quickjs/firefly_runtime.c`, built as a WASI reactor with Debian's
clang and wasi-libc. `wasm/quickjs/build.sh` rebuilds it in Docker,
reproducibly; the runtime refuses to load a `.wasm` that doesn't match the
committed `quickjs.wasm.sha256`, and a test checks it.
