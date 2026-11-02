defmodule FirestormWeb.Plugins.UI do
  @moduledoc """
  What plugins add to the interface: widgets, pages, staff sections and
  inbound HTTP endpoints.

  **Widgets** (manifest `widgets`: `{outlet, asset, height}`) are the
  plugin's own HTML assets, shown in fixed outlets (`post_footer`,
  `thread_header`, `sidebar`, `user_profile`, `composer`) inside sandboxed
  frames: `sandbox="allow-scripts"` without `allow-same-origin`, so the
  widget runs in an opaque origin with no access to the page, its cookies or
  storage, and its asset is served with a strict Content Security Policy
  (no network access at all: `connect-src 'none'`). The widget talks to the
  page only through a small `postMessage` bridge (the SDK at
  `/plugins/sdk.js`): it gets the viewer's public profile and its context
  (e.g. the post id), can ask to be resized, and can call the plugin's own
  `handle_widget` handler on the server. Widgets about a post or thread only
  appear on content anonymous visitors can read.

  **Pages** at `/plugins/:id/*path` come from `render_page`: sanitized HTML
  in the site's layout, or the plugin's asset as a sandboxed app. A plugin's
  **staff section** on `/staff/plugins/:id` comes from `render_admin`,
  likewise.

  **Endpoints** at `/api/plugins/:id/*path` call `handle_request`. Callers
  authenticate as the manifest's `endpoint_auth` says: `secret` (the
  `x-plugin-secret` header, shown to staff on the plugin's page), `user` (a
  member's API token, `Authorization: Bearer`), or `either`. Rate limited
  per plugin and caller.
  """

  alias FirestormWeb.{Plugin, Plugins, RateLimit}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Plugin.Runner
  alias FirestormWeb.Plugins.Content

  @doc "The active plugins' widgets for `outlet`, in plugin order: `[{plugin, widget}]`."
  def widgets(outlet) do
    for plugin <- Plugins.active(),
        widget <- plugin.manifest.widgets,
        widget["outlet"] == outlet do
      {plugin, widget}
    end
  end

  @doc "A user's public profile, as plugins see it (nil for visitors)."
  def public_user(%User{} = user), do: %{id: user.id, username: user.username, name: user.name}
  def public_user(_visitor), do: nil

  @doc """
  A widget calls `handler` of plugin `id`. Rate limited per viewer. Returns
  `{:ok, result}` or `{:error, message}` for the widget.
  """
  def call_widget(id, handler, args, context, user, caller) do
    with %Plugin{} = plugin <- Plugins.get_active(id),
         true <- plugin.manifest.widgets != [] and Plugin.implements?(plugin, "handle_widget"),
         :ok <- RateLimit.check(:plugin_call, caller) do
      input = %{
        "handler" => handler,
        "args" => args,
        "context" => context,
        "user" => public_user(user)
      }

      case Runner.invoke(plugin, "handle_widget", [input]) do
        {:ok, result} -> {:ok, result}
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, _failure} -> {:error, "the plugin failed"}
      end
    else
      {:error, :rate_limited} -> {:error, "too many calls: slow down"}
      _ -> {:error, "no such plugin"}
    end
  end

  @doc """
  Plugin `id`'s page at `path` (`hook` `"render_page"`) or staff section
  (`"render_admin"`): `{:ok, %{title, html}}`, `{:ok, %{title, iframe}}`
  or `{:error, reason}`.
  """
  def render(id, hook, input) when hook in ["render_page", "render_admin"] do
    with %Plugin{} = plugin <- Plugins.get_active(id),
         {:ok, %{} = result} <- Runner.invoke(plugin, hook, [input]) do
      view(plugin, result)
    else
      nil -> {:error, :not_found}
      {:error, :not_implemented} -> {:error, :not_found}
      _failed -> {:error, :failed}
    end
  end

  defp view(plugin, %{"iframe" => asset} = result) when is_binary(asset) do
    if asset in plugin.manifest.assets,
      do: {:ok, %{title: title(plugin, result), iframe: asset}},
      else: {:error, :failed}
  end

  defp view(plugin, %{"html" => html} = result) when is_binary(html),
    do: {:ok, %{title: title(plugin, result), html: Content.sanitize(html)}}

  defp view(_plugin, _result), do: {:error, :failed}

  defp title(plugin, result) do
    case result["title"] do
      title when is_binary(title) and title != "" -> String.slice(title, 0, 120)
      _ -> plugin.manifest.name
    end
  end

  @doc "Plugin `id`'s asset at `path`: `{:ok, binary}` or `:error`."
  def asset(id, path) do
    with %Plugin{module: module} = plugin <- Plugins.get_active(id),
         true <- path in plugin.manifest.assets,
         true <- function_exported?(module, :asset, 2) do
      module.asset(plugin, path)
    else
      _ -> :error
    end
  end

  @doc """
  Handles a request to plugin `id`'s endpoint. `auth` is what the caller
  presented: `%{secret, user}`. Returns `{status, body}`.
  """
  def request(id, input, %{secret: secret, user: user}, caller) do
    with %Plugin{} = plugin <- Plugins.get_active(id),
         true <- Plugin.implements?(plugin, "handle_request") || :not_found,
         :ok <- authenticate(plugin, secret, user),
         :ok <- RateLimit.check(:plugin_api, "#{id}:#{caller}") do
      input = Map.put(input, "user", public_user(user))

      case Runner.invoke(plugin, "handle_request", [input]) do
        {:ok, %{"status" => status} = response} when status in 200..599 ->
          {status, response["body"]}

        {:ok, response} ->
          {200, response}

        {:error, message} when is_binary(message) ->
          {400, %{error: message}}

        {:error, _failure} ->
          {502, %{error: "the plugin failed"}}
      end
    else
      nil -> {404, %{error: "not found"}}
      :not_found -> {404, %{error: "not found"}}
      :unauthorized -> {401, %{error: "authentication required"}}
      {:error, :rate_limited} -> {429, %{error: RateLimit.message()}}
    end
  end

  defp authenticate(plugin, secret, user) do
    by_secret =
      is_binary(secret) and Plug.Crypto.secure_compare(secret, Plugins.secret(plugin.id))

    by_user = match?(%User{}, user)

    allowed =
      case plugin.manifest.endpoint_auth do
        "secret" -> by_secret
        "user" -> by_user
        "either" -> by_secret or by_user
      end

    if allowed, do: :ok, else: :unauthorized
  end

  @doc """
  The Content Security Policy for plugin assets: nothing from elsewhere, no
  network, and sandboxed even if opened directly.
  """
  def csp do
    "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; " <>
      "img-src 'self' data:; font-src 'self'; connect-src 'none'; form-action 'none'; " <>
      "base-uri 'none'; frame-ancestors 'self'; sandbox allow-scripts"
  end
end
