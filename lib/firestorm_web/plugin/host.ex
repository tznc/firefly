defmodule FirestormWeb.Plugin.Host do
  @moduledoc """
  The host functions plugins call: `firefly.call(name, args)` in a sandboxed
  plugin, `call/3` in a core one. Arguments and results are JSON-like data.

  Deny by default: a function either needs nothing (it only touches the
  plugin's own things) or one permission, which the plugin must list in its
  manifest. Staff see an uploaded plugin's permissions before installing
  it; core plugins are trusted, but the same checks apply, so a core
  plugin's manifest documents what it does too. A denial is logged in the
  plugin's error log.

  Whatever a function reads or writes goes through the same contexts and
  policies as people: reads see only what an anonymous visitor may (see
  `FirestormWeb.Forums.Post.readable_by?/2` and the `:view_thread` policy),
  so private categories stay private.

  ## Functions

    * `log` - `{level, message}`: to the server log, tagged with the plugin.
    * `settings` - the plugin's current settings.
    * `site` - the site's title, URL and plugin API version.
    * `plugins.call` - `{plugin, function, args}`: calls a function another
      plugin exports. Only plugins this one depends on (required or
      optional), only their manifest `exports`, and only while they're
      active.
    * `posts.get` (`read`) - `{id}`: a public post.
    * `threads.get` (`read`) - `{id}`: a public thread.
    * `users.get` (`read`) - `{id}` or `{username}`: a user's public profile.
  """

  require Logger

  alias FirestormWeb.{Forums, Plugins, Repo, SiteSettings}
  alias FirestormWeb.Forums.{Post, Thread, User}
  alias FirestormWeb.Plugin
  alias FirestormWeb.Web.Paths

  @permissions %{
    "read" => "Read public posts, threads and user profiles"
  }

  # Function name => the permission it needs (nil: none).
  @functions %{
    "log" => nil,
    "settings" => nil,
    "site" => nil,
    "plugins.call" => nil,
    "posts.get" => "read",
    "threads.get" => "read",
    "users.get" => "read"
  }

  @doc "Every permission a manifest may request."
  def permissions, do: Map.keys(@permissions)

  @doc "What a permission lets a plugin do, for staff."
  def describe_permission(permission), do: Map.fetch!(@permissions, permission)

  @doc "Every host function, with the permission it needs."
  def functions, do: @functions

  @doc """
  Calls host function `name` for `plugin`: `{:ok, result}` or
  `{:error, message}` (the message is for the plugin).
  """
  @spec call(Plugin.t(), String.t(), term) :: {:ok, term} | {:error, String.t()}
  def call(%Plugin{} = plugin, name, args) do
    case Map.fetch(@functions, name) do
      :error ->
        {:error, "unknown function #{name}"}

      {:ok, permission} ->
        if is_nil(permission) or permission in plugin.manifest.permissions do
          run(name, plugin, args)
        else
          message = "permission denied: #{name} needs the \"#{permission}\" permission"
          Plugins.log_error(plugin.id, name, :denied, message)
          {:error, message}
        end
    end
  end

  defp run("log", plugin, args) do
    message = String.slice(to_string(args["message"]), 0, 2_000)

    case args["level"] do
      level when level in ["warn", "warning"] ->
        Logger.warning("[plugin #{plugin.id}] #{message}")

      "error" ->
        Logger.error("[plugin #{plugin.id}] #{message}")

      _info ->
        Logger.info("[plugin #{plugin.id}] #{message}")
    end

    {:ok, nil}
  end

  defp run("settings", plugin, _args), do: {:ok, plugin.settings}

  defp run("site", _plugin, _args) do
    {:ok,
     %{
       title: SiteSettings.get("title"),
       url: FirestormWeb.Web.Endpoint.url(),
       api_version: Plugin.api_version()
     }}
  end

  defp run("plugins.call", plugin, %{"plugin" => target, "function" => function} = args)
       when is_binary(target) and is_binary(function),
       do: Plugins.call_export(plugin, target, function, Map.get(args, "args"))

  defp run("posts.get", _plugin, %{"id" => id}) when is_integer(id) do
    with %Post{} = post <- Repo.get(Post, id),
         post = Repo.preload(post, [:user, :thread]),
         true <- Post.readable_by?(post, nil) and public_thread?(post.thread) do
      {:ok,
       %{
         id: post.id,
         thread_id: post.thread_id,
         author: post.user && post.user.username,
         body: post.body,
         url: "#{Paths.thread_url(post.thread)}#post-#{post.id}",
         created_at: post.inserted_at
       }}
    else
      _ -> {:error, "not found"}
    end
  end

  defp run("threads.get", _plugin, %{"id" => id}) when is_integer(id) do
    with %Thread{} = thread <- Repo.get(Thread, id),
         true <- public_thread?(thread) do
      {:ok,
       %{
         id: thread.id,
         title: thread.title,
         category_id: thread.category_id,
         url: Paths.thread_url(thread),
         closed: not is_nil(thread.closed_at),
         created_at: thread.inserted_at
       }}
    else
      _ -> {:error, "not found"}
    end
  end

  defp run("users.get", _plugin, args) do
    user =
      case args do
        %{"id" => id} when is_integer(id) -> Forums.get_user(id)
        %{"username" => name} when is_binary(name) -> Forums.get_user_by_username(name)
        _ -> nil
      end

    case user do
      %User{deleted_at: nil} = user ->
        {:ok, %{id: user.id, username: user.username, name: user.name}}

      _ ->
        {:error, "not found"}
    end
  end

  defp run(name, _plugin, _args), do: {:error, "invalid arguments for #{name}"}

  defp public_thread?(thread), do: Bodyguard.permit?(Forums, :view_thread, nil, thread)
end
