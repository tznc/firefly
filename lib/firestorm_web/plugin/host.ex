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
    * `kv.get`, `kv.set`, `kv.delete`, `kv.list` - `{key}`, `{key, value}`,
      `{key}`, `{prefix}`: the plugin's own storage (see
      `FirestormWeb.Plugins.Storage`).
    * `tags.add`, `tags.remove` (`tags`) - `{thread_id, tag}`.
    * `posts.reply` (`post`) - `{thread_id, body}`: replies as the plugin's
      bot; the result is `{id}`.
    * `posts.flag` (`flag`) - `{post_id, reason, note}` (reason: spam,
      inappropriate, off_topic or other).
    * `notifications.send` (`notify`) - `{user_id}` or `{username}`, with
      `{subject, body, path}` (`path` on this site, default `/`). At most 100
      an hour per plugin.
    * `threads.close`, `threads.pin` (`moderate`) - `{thread_id, closed}`,
      `{thread_id, pinned}`.
    * `http.fetch` (`http`) - see `FirestormWeb.Plugins.HTTP`.
    * `fields.get`, `fields.set` (`fields`) - `{type, id}`, `{type, id, key,
      value}`: see `FirestormWeb.Plugins.Fields`.

  Writes act as the plugin's bot user (see `FirestormWeb.Plugins.Bots`)
  through the same contexts, policies and checks as a member's
  (`FirestormWeb.Posting`, rate limits, tag groups, the review queue), and
  only on threads and posts anyone can read.
  """

  require Logger

  alias FirestormWeb.{Flags, Forums, Plugins, Posting, RateLimit, Repo, SiteSettings}
  alias FirestormWeb.Forums.{Post, Thread, User}
  alias FirestormWeb.Plugin
  alias FirestormWeb.Plugins.{Bots, Fields, HTTP, Storage}
  alias FirestormWeb.Web.Paths

  @permissions %{
    "read" => "Read public posts, threads and user profiles, and hear about events",
    "tags" => "Add and remove tags on public threads, as its bot",
    "flag" => "Flag public posts as its bot, and hear about flags raised",
    "post" => "Reply in public threads as its bot",
    "notify" => "Send members notifications",
    "moderate" => "Close, reopen, pin and unpin public threads as its bot",
    "http" => "Make HTTP requests to the hosts it lists",
    "fields" => "Keep its own fields on posts, threads and users"
  }

  # Function name => the permission it needs (nil: none).
  @functions %{
    "log" => nil,
    "settings" => nil,
    "site" => nil,
    "plugins.call" => nil,
    "posts.get" => "read",
    "threads.get" => "read",
    "users.get" => "read",
    "kv.get" => nil,
    "kv.set" => nil,
    "kv.delete" => nil,
    "kv.list" => nil,
    "tags.add" => "tags",
    "tags.remove" => "tags",
    "posts.reply" => "post",
    "posts.flag" => "flag",
    "notifications.send" => "notify",
    "threads.close" => "moderate",
    "threads.pin" => "moderate",
    "http.fetch" => "http",
    "fields.get" => "fields",
    "fields.set" => "fields"
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

  defp run("kv.get", plugin, %{"key" => key}) when is_binary(key),
    do: {:ok, Storage.get(plugin.id, key)}

  defp run("kv.set", plugin, %{"key" => key} = args),
    do: ok(Storage.put(plugin.id, key, args["value"]))

  defp run("kv.delete", plugin, %{"key" => key}) when is_binary(key),
    do: ok(Storage.delete(plugin.id, key))

  defp run("kv.list", plugin, args),
    do: {:ok, Storage.list(plugin.id, to_string(args["prefix"] || ""))}

  defp run(name, plugin, %{"thread_id" => id, "tag" => tag})
       when name in ["tags.add", "tags.remove"] and is_binary(tag) do
    bot = Bots.ensure(plugin)

    with {:ok, thread} <- public_thread(id),
         :ok <- permit(:tag_thread, bot, thread),
         :ok <- message(Posting.check(bot, :like)) do
      thread = Repo.preload(thread, :tags)
      names = Enum.map(thread.tags, & &1.name)
      names = if name == "tags.add", do: names ++ [tag], else: names -- [tag]

      case Forums.update_thread(thread, %{tags: Enum.join(names, ",")}, bot) do
        {:ok, updated} ->
          {:ok, Enum.map(Repo.preload(updated, :tags, force: true).tags, & &1.name)}

        {:error, changeset} ->
          {:error, changeset_message(changeset)}
      end
    end
  end

  defp run("posts.reply", plugin, %{"thread_id" => id, "body" => body}) when is_binary(body) do
    bot = Bots.ensure(plugin)

    with {:ok, thread} <- public_thread(id),
         :ok <- bot |> Posting.check(thread) |> message() do
      case Forums.create_post(thread, bot, %{body: body}) do
        {:ok, post} -> {:ok, %{id: post.id}}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_message(changeset)}
        {:error, reason} -> {:error, Posting.message(reason)}
      end
    end
  end

  defp run("posts.flag", plugin, %{"post_id" => id} = args) when is_integer(id) do
    bot = Bots.ensure(plugin)

    with {:ok, post} <- public_post(id) do
      case Flags.flag_post(post, bot, %{reason: args["reason"] || "other", note: args["note"]}) do
        {:ok, flag} -> {:ok, %{id: flag.id}}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_message(changeset)}
        {:error, reason} -> {:error, Flags.message(reason)}
      end
    end
  end

  defp run("notifications.send", plugin, %{"subject" => subject, "body" => body} = args)
       when is_binary(subject) and is_binary(body) do
    path = args["path"] || "/"

    with %User{deleted_at: nil} = user <- recipient(args),
         true <- String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
         :ok <- RateLimit.check(:plugin_notify, plugin.id) do
      {:ok, _} =
        Forums.notify(user, %{
          kind: "plugin",
          subject: String.slice("#{plugin.manifest.name}: #{subject}", 0, 200),
          body: String.slice(body, 0, 2_000),
          url: FirestormWeb.Web.Endpoint.url() <> path
        })

      {:ok, nil}
    else
      false -> {:error, "path must be a path on this site, like /t/1"}
      {:error, :rate_limited} -> {:error, "too many notifications: try again later"}
      _ -> {:error, "no such user"}
    end
  end

  defp run(name, plugin, %{"thread_id" => id} = args)
       when name in ["threads.close", "threads.pin"] do
    bot = Bots.ensure(plugin)
    on = if name == "threads.close", do: args["closed"], else: args["pinned"]

    with true <- is_boolean(on) || {:error, "say whether: true or false"},
         {:ok, thread} <- public_thread(id),
         :ok <- permit(:moderate_thread, bot, thread) do
      result =
        if name == "threads.close",
          do: Forums.close_thread(thread, on, bot),
          else: Forums.pin_thread(thread, on, bot)

      case result do
        {:ok, _thread} -> {:ok, nil}
        {:error, _} -> {:error, "#{name} failed"}
      end
    end
  end

  defp run("http.fetch", plugin, args) when is_map(args),
    do: HTTP.fetch(plugin.manifest.http_hosts, args)

  defp run("fields.get", plugin, %{"type" => type, "id" => id}) when is_integer(id) do
    with :ok <- field_target(type, id), do: {:ok, Fields.get(plugin.id, type, id)}
  end

  defp run("fields.set", plugin, %{"type" => type, "id" => id, "key" => key} = args)
       when is_integer(id) and is_binary(key) do
    with :ok <- field_target(type, id), do: ok(Fields.put(plugin, type, id, key, args["value"]))
  end

  defp run(name, _plugin, _args), do: {:error, "invalid arguments for #{name}"}

  defp ok(:ok), do: {:ok, nil}
  defp ok(error), do: error

  defp message(:ok), do: :ok
  defp message({:error, reason}), do: {:error, Posting.message(reason)}

  defp permit(action, user, thread) do
    case Bodyguard.permit(Forums, action, user, thread) do
      :ok -> :ok
      {:error, _} -> {:error, "not allowed"}
    end
  end

  defp public_thread(id) when is_integer(id) do
    case Repo.get(Thread, id) do
      %Thread{} = thread ->
        if public_thread?(thread), do: {:ok, thread}, else: {:error, "not found"}

      nil ->
        {:error, "not found"}
    end
  end

  defp public_thread(_id), do: {:error, "not found"}

  defp public_post(id) do
    with %Post{} = post <- Repo.get(Post, id),
         post = Repo.preload(post, :thread),
         true <- Post.readable_by?(post, nil) and public_thread?(post.thread) do
      {:ok, post}
    else
      _ -> {:error, "not found"}
    end
  end

  defp field_target(type, id) do
    found =
      case type do
        "post" -> match?({:ok, _}, public_post(id))
        "thread" -> match?({:ok, _}, public_thread(id))
        "user" -> match?(%User{deleted_at: nil}, Forums.get_user(id))
        _ -> false
      end

    if found, do: :ok, else: {:error, "not found"}
  end

  defp recipient(%{"user_id" => id}) when is_integer(id), do: Forums.get_user(id)

  defp recipient(%{"username" => name}) when is_binary(name),
    do: Forums.get_user_by_username(name)

  defp recipient(_args), do: nil

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        to_string(opts[String.to_existing_atom(key)])
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.map_join(List.wrap(messages), ", ", &text/1)}"
    end)
  end

  # Nested changesets' errors are maps.
  defp text(message) when is_binary(message), do: message
  defp text(other), do: inspect(other)

  defp public_thread?(thread), do: Bodyguard.permit?(Forums, :view_thread, nil, thread)
end
