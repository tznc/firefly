defmodule FirestormWeb.Plugin do
  @moduledoc """
  The plugin contract. Every plugin, whatever it's written in, is a module
  implementing this behaviour, and host code (the registry, hook dispatch,
  permissions, settings, the staff log, the circuit breaker) only ever talks
  to plugins through it.

  There are two kinds:

    * **Core plugins** ship with Firefly: Elixir modules (or Elixir modules
      wrapping a Rust NIF; nothing here assumes the code is pure Elixir)
      that `use FirestormWeb.Plugin` and are listed in config:

          config :firestorm_web, FirestormWeb.Plugins, core: [MyApp.HelloPlugin]

      They're trusted: their permissions are granted without a prompt.
      Staff still see them at `/staff/plugins` and can disable them.

    * **Uploaded plugins** are third-party JavaScript bundles (see
      `FirestormWeb.Plugin.Bundle`), all served by one implementation,
      `FirestormWeb.Plugin.Sandboxed`, which runs them in QuickJS on
      WebAssembly. Staff see the permissions they request before installing.

  A loaded plugin is a `t:t/0`: its manifest (see
  `FirestormWeb.Plugin.Manifest`), current settings, and the implementation's
  own `state` (the sandboxed one keeps the bundle's code there). Every
  callback after `c:load/1` gets it as its first argument, so one module can
  serve many plugins.

  Hook callbacks are optional: a plugin implements the ones it uses. Which
  ones that is lives in the manifest's `hooks` (a core plugin's is filled
  in from the callbacks it defines), so the host never calls a hook the
  plugin didn't declare. A plugin with `exports` implements `c:call_export/3`. All calls go through `FirestormWeb.Plugin.Runner`,
  which applies the same time limit, error handling, statistics and circuit
  breaker to both kinds.

  ## Writing a core plugin

      defmodule MyApp.HelloPlugin do
        use FirestormWeb.Plugin,
          id: "hello",
          name: "Hello",
          version: "1.0.0",
          firefly: "~> 1.0",
          description: "Says hello.",
          author: "Firefly",
          exports: ["greet"]

        @impl true
        def call_export(_plugin, "greet", %{"name" => name}), do: {:ok, "Hello, " <> name}
      end

  The keyword list is the manifest (atom or string keys), validated when the
  plugin loads. Host functions (the same ones a sandboxed plugin reaches
  through `firefly.call`) are at `FirestormWeb.Plugin.Host.call/3`, with the
  same permission checks.
  """

  alias FirestormWeb.Plugin.Manifest

  @enforce_keys [:id, :module, :manifest]
  defstruct [:id, :module, :manifest, :state, source: "core", settings: %{}, fail_closed: false]

  @type t :: %__MODULE__{
          id: String.t(),
          module: module,
          manifest: Manifest.t(),
          state: term,
          source: String.t(),
          settings: map,
          fail_closed: boolean
        }

  @typedoc "A hook's failure: what went wrong and a message for the error log."
  @type failure :: {atom, String.t()}

  @doc """
  The plugin's manifest and implementation state, from `spec`: nothing for
  a core plugin, the stored bundle for an uploaded one.
  """
  @callback load(spec :: term) :: {:ok, Manifest.t(), state :: term} | {:error, String.t()}

  @doc "The plugin was enabled (or resumed); a chance to set things up."
  @callback enabled(t) :: :ok | {:error, failure}

  @doc "The plugin was disabled (or suspended)."
  @callback disabled(t) :: :ok | {:error, failure}

  @doc """
  Another plugin that depends on this one calls `function`, one of this
  plugin's manifest `exports`, with `args` (JSON-like data). See
  `FirestormWeb.Plugin.Host`'s `plugins.call`.
  """
  @callback call_export(t, function :: String.t(), args :: term) ::
              {:ok, term} | {:error, String.t() | failure}

  @doc """
  Transforms a post's rendered, sanitized HTML. `input` is
  `%{"html" => html, "post" => context}` (see `FirestormWeb.Plugins.Content`);
  the result is the new HTML, sanitized again before it's shown. Runs only
  for posts anonymous visitors can read.
  """
  @callback render_post(t, input :: map) :: {:ok, String.t()} | {:error, failure}

  @doc """
  Renders the plugin's shortcodes (its manifest `shortcodes`) found in a
  post: `input` is `%{"shortcodes" => [%{"name", "attrs", "content"}],
  "post" => context}`; the result is one HTML string per shortcode, in order.
  """
  @callback render_shortcodes(t, input :: map) :: {:ok, [String.t()]} | {:error, failure}

  @doc """
  An event the plugin subscribed to (manifest `events`) happened: `input`
  is `%{"event" => name, "data" => data}` (see `FirestormWeb.Plugins.Events`).
  Delivered asynchronously, retried on failure.
  """
  @callback handle_event(t, input :: map) :: :ok | {:ok, term} | {:error, failure}

  @doc "A scheduled job (manifest `jobs`) is due: `input` is `%{\"job\" => name}`."
  @callback run_job(t, input :: map) :: :ok | {:ok, term} | {:error, failure}

  @doc """
  Checks a new thread, reply or edit before it's saved, synchronously and
  under a strict time limit: `input` is `%{"kind" => "thread" | "post" |
  "edit", "title", "body", "user", "thread", "category_id"}`. The result is
  `%{"action" => "allow"}`, `%{"action" => "queue", "reason" => text}`
  (staff review it first) or `%{"action" => "reject", "message" => text}`
  (shown to the author). See `FirestormWeb.Plugins.Moderation`.
  """
  @callback moderate_post(t, input :: map) :: {:ok, map} | {:error, failure}

  @doc """
  A member flagged a post: `input` is `%{"post", "thread", "flag" =>
  %{"reason", "note"}}`. The result is `%{"action" => "none"}` or
  `%{"action" => "hide"}` (hide the post until staff review it).
  """
  @callback flag_created(t, input :: map) :: {:ok, map} | {:error, failure}

  @doc """
  A widget (see the manifest's `widgets`) called one of the plugin's
  handlers through the widget bridge: `input` is `%{"handler", "args",
  "context", "user"}`. `context` comes from the browser: treat it as
  untrusted. `user` is the viewer's public profile, or nil.
  """
  @callback handle_widget(t, input :: map) :: {:ok, term} | {:error, String.t() | failure}

  @doc """
  Renders the plugin's page at `/plugins/:id/*path`: `input` is `%{"path",
  "params", "user"}`; the result is `%{"title", "html"}` (sanitized, shown
  in the site's layout) or `%{"title", "iframe" => asset}` (an app in a
  sandboxed frame).
  """
  @callback render_page(t, input :: map) :: {:ok, map} | {:error, String.t() | failure}

  @doc "Renders the plugin's own section of its staff page (`/staff/plugins/:id`), as `render_page/2`."
  @callback render_admin(t, input :: map) :: {:ok, map} | {:error, String.t() | failure}

  @doc """
  Handles a request to `/api/plugins/:id/*path`: `input` is `%{"method",
  "path", "query", "body", "user"}`; the result is `%{"status", "body"}`,
  sent as JSON.
  """
  @callback handle_request(t, input :: map) :: {:ok, map} | {:error, String.t() | failure}

  @doc """
  One of the plugin's static assets (manifest `assets`), for widgets and
  frames: `{:ok, binary}` or `:error`. Not a hook: no sandbox call.
  """
  @callback asset(t, path :: String.t()) :: {:ok, binary} | :error

  @optional_callbacks enabled: 1,
                      handle_widget: 2,
                      render_page: 2,
                      render_admin: 2,
                      handle_request: 2,
                      asset: 2,
                      moderate_post: 2,
                      flag_created: 2,
                      disabled: 1,
                      call_export: 3,
                      render_post: 2,
                      render_shortcodes: 2,
                      handle_event: 2,
                      run_job: 2

  # Hook name (as in manifests) => callback.
  @hooks %{
    "enabled" => {:enabled, 1},
    "disabled" => {:disabled, 1},
    "call_export" => {:call_export, 3},
    "render_post" => {:render_post, 2},
    "render_shortcodes" => {:render_shortcodes, 2},
    "handle_event" => {:handle_event, 2},
    "run_job" => {:run_job, 2},
    "moderate_post" => {:moderate_post, 2},
    "flag_created" => {:flag_created, 2},
    "handle_widget" => {:handle_widget, 2},
    "render_page" => {:render_page, 2},
    "render_admin" => {:render_admin, 2},
    "handle_request" => {:handle_request, 2}
  }

  @doc "The hooks a plugin may implement, by manifest name, with their callbacks."
  def hooks, do: @hooks

  @doc """
  The plugin API version: a manifest's `firefly` requirement must match it.
  Minor versions add hooks and host functions; a major version would break
  existing plugins.
  """
  def api_version, do: "1.0.0"

  @doc """
  The hooks a manifest lists. `call_export` isn't one: a plugin implements it
  when it has `exports`.
  """
  def manifest_hooks, do: Map.keys(@hooks) -- ["call_export"]

  @doc "Whether `plugin` implements `hook` (a manifest hook name)."
  def implements?(%__MODULE__{manifest: manifest}, "call_export"), do: manifest.exports != []
  def implements?(%__MODULE__{manifest: manifest}, hook), do: hook in manifest.hooks

  defmacro __using__(manifest) do
    quote do
      @behaviour FirestormWeb.Plugin
      @firefly_manifest unquote(manifest)
      @before_compile FirestormWeb.Plugin
    end
  end

  defmacro __before_compile__(env) do
    hooks =
      for {hook, {name, arity}} <- @hooks,
          hook in manifest_hooks(),
          Module.defines?(env.module, {name, arity}, :def),
          do: hook

    quote do
      @impl FirestormWeb.Plugin
      def load(_spec) do
        attrs =
          @firefly_manifest
          |> FirestormWeb.Plugin.Manifest.stringify()
          |> Map.put("hooks", unquote(Enum.sort(hooks)))

        with {:ok, manifest} <- FirestormWeb.Plugin.Manifest.parse(attrs, "core"),
             do: {:ok, manifest, nil}
      end
    end
  end
end
