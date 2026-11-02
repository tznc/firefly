defmodule Firefly.Plugin.Host do
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
  `Firefly.Forums.Post.readable_by?/2` and the `:view_thread` policy),
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
      `Firefly.Plugins.Storage`). With `user_id`, the store the plugin
      keeps for that member (who must exist), a separate namespace with its
      own quota.
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
    * `http.fetch` (`http`) - see `Firefly.Plugins.HTTP`. Only in
      hooks that run in the background or on the plugin's own surfaces
      (see "Network access" below), and every attempt is logged (see
      `Firefly.Plugins.Egress`).
    * `fields.get`, `fields.set` (`fields`) - `{type, id}`, `{type, id, key,
      value}`: see `Firefly.Plugins.Fields`.

  Writes act as the plugin's bot user (see `Firefly.Plugins.Bots`)
  through the same contexts, policies and checks as a member's
  (`Firefly.Posting`, rate limits, tag groups, the review queue), and
  only on threads and posts anyone can read.

  ## Network access

  `http.fetch` is refused, whatever the plugin's permissions, while a
  hook runs synchronously in a member's request on forum content
  (`render_shortcodes`, `render_post`, `moderate_post`, `flag_created`): a slow or hostile host would hold up
  every page view, and content would leave the site each time it's shown.
  It's allowed in `enabled` and `disabled` (staff actions), `handle_event`
  and `run_job` (background work), on the plugin's own surfaces, where the
  caller asked for the plugin and waits for it (`handle_widget`,
  `handle_request`, `render_page`, `render_admin`; still within the hook's
  time limit), and in an export when the call chain started in one of those
  (see `Firefly.Plugin.Runner.context/0`).
  The check reads the context the runner gave the calling process, so it
  holds the same for core and sandboxed plugins, and a process a core
  plugin starts outside a hook gets no network either.
  """

  require Logger

  alias Firefly.{Flags, Forums, Plugin, Plugins, Posting, RateLimit, Repo, SiteSettings, URLs}
  alias Firefly.Forums.{Post, Thread, User}
  alias Firefly.Plugin.{Manifest, Runner}
  alias Firefly.Plugins.{Bots, Egress, Fields, HTTP, Storage}

  # What each permission lets a plugin do, in words for staff deciding
  # whether to install it. `http` is followed by the hosts it names.
  @permissions %{
    "read" =>
      "Can read public posts, threads and member profiles, and is told when they're created, edited or deleted",
    "tags" => "Can add and remove tags on public threads, as its bot account",
    "flag" =>
      "Can flag public posts for staff review, as its bot account, and is told when members flag posts",
    "post" => "Can reply in public threads, as its bot account",
    "notify" => "Can send members notifications (at most 100 an hour)",
    "moderate" => "Can close, reopen, pin and unpin public threads, as its bot account",
    "http" => "Can send forum content to:",
    "fields" => "Can keep its own data on posts, threads and member profiles"
  }

  # Where `http.fetch` may run (see "Network access").
  @network_contexts ~w(enabled disabled handle_event run_job
                       handle_widget handle_request render_page render_admin)

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

  @doc """
  What `permission` lets the plugin with `manifest` do, in plain words for
  staff: for `http`, "Can send forum content to: " and its hosts.
  """
  def describe_permission(permission, %Manifest{} = manifest) do
    case permission do
      "http" -> "#{@permissions["http"]} #{Enum.map_join(manifest.http_hosts, ", ", &host/1)}"
      _ -> Map.fetch!(@permissions, permission)
    end
  end

  @doc """
  What `manifest` asks for, for staff, in its order:
  `[%{permission, text, new, hosts}]` (`text` from `describe_permission/2`),
  `hosts` being the `http` permission's `[%{name, new}]`. Given `previous` (the installed version's
  manifest, when upgrading), `new` marks what this version adds.
  """
  def permission_summary(%Manifest{} = manifest, previous \\ nil) do
    for permission <- manifest.permissions do
      %{
        permission: permission,
        text: describe_permission(permission, manifest),
        new: added?(previous, :permissions, permission),
        hosts:
          if(permission == "http",
            do: for(pattern <- manifest.http_hosts, do: host_summary(previous, pattern)),
            else: []
          )
      }
    end
  end

  @doc "Whether `manifest` asks for any permission or host `previous` didn't."
  def more_access?(%Manifest{} = manifest, %Manifest{} = previous) do
    manifest
    |> permission_summary(previous)
    |> Enum.any?(fn item -> item.new or Enum.any?(item.hosts, & &1.new) end)
  end

  defp host_summary(previous, pattern),
    do: %{name: host(pattern), new: added?(previous, :http_hosts, pattern)}

  defp added?(nil, _key, _value), do: false
  defp added?(%Manifest{} = previous, key, value), do: value not in Map.fetch!(previous, key)

  defp host("*." <> domain), do: "any subdomain of #{domain}"
  defp host(name), do: name

  @doc "Every host function, with the permission it needs."
  def functions, do: @functions

  @doc """
  Calls host function `name` for `plugin`: `{:ok, result}` or
  `{:error, message}` (the message is for the plugin).
  """
  @spec call(Plugin.t(), String.t(), term) :: {:ok, term} | {:error, String.t()}
  def call(%Plugin{} = plugin, "http.fetch", args) do
    started = System.monotonic_time(:millisecond)

    result =
      with :ok <- permitted(plugin, "http.fetch"),
           :ok <- network_context(),
           do: HTTP.fetch(plugin.manifest.http_hosts, args)

    Egress.record(plugin.id, args, result, System.monotonic_time(:millisecond) - started)

    case result do
      {:ok, response} ->
        {:ok, response}

      {:error, kind, message} when kind in [:no_permission, :sync_hook] ->
        denied(plugin, "http.fetch", message)

      {:error, _kind, message} ->
        {:error, message}
    end
  end

  def call(%Plugin{} = plugin, name, args) do
    if Map.has_key?(@functions, name) do
      case permitted(plugin, name) do
        :ok -> run(name, plugin, args)
        {:error, _kind, message} -> denied(plugin, name, message)
      end
    else
      {:error, "unknown function #{name}"}
    end
  end

  defp permitted(plugin, name) do
    permission = @functions[name]

    if is_nil(permission) or permission in plugin.manifest.permissions,
      do: :ok,
      else:
        {:error, :no_permission,
         "permission denied: #{name} needs the \"#{permission}\" permission"}
  end

  defp network_context do
    case Runner.context() do
      context when context in @network_contexts ->
        :ok

      context ->
        {:error, :sync_hook,
         "permission denied: http.fetch is not available in synchronous hooks (#{context || "outside a hook"}); use an event or job"}
    end
  end

  # A denial is logged in the plugin's error log.
  defp denied(plugin, name, message) do
    Plugins.log_error(plugin.id, name, :denied, message)
    {:error, message}
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
       url: Firefly.Endpoint.url(),
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
         url: "#{URLs.thread_url(post.thread)}#post-#{post.id}",
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
         url: URLs.thread_url(thread),
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

  defp run("kv." <> op, plugin, args) do
    with {:ok, scope} <- kv_scope(plugin, args), do: kv(op, scope, args)
  end

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
          url: Firefly.Endpoint.url() <> path
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

  defp run("fields.get", plugin, %{"type" => type, "id" => id}) when is_integer(id) do
    with :ok <- field_target(type, id), do: {:ok, Fields.get(plugin.id, type, id)}
  end

  defp run("fields.set", plugin, %{"type" => type, "id" => id, "key" => key} = args)
       when is_integer(id) and is_binary(key) do
    with :ok <- field_target(type, id), do: ok(Fields.put(plugin, type, id, key, args["value"]))
  end

  defp run(name, _plugin, _args), do: {:error, "invalid arguments for #{name}"}

  # `user_id` picks a member's store instead of the plugin's global one. Any
  # existing member will do: server-side code decides whose data it keeps.
  defp kv_scope(plugin, %{"user_id" => nil}), do: {:ok, plugin.id}

  defp kv_scope(plugin, %{"user_id" => id}) when is_integer(id) do
    case Forums.get_user(id) do
      %User{deleted_at: nil} -> {:ok, {plugin.id, id}}
      _ -> {:error, "user not found"}
    end
  end

  defp kv_scope(_plugin, %{"user_id" => _}), do: {:error, "user_id must be a user's id"}
  defp kv_scope(plugin, _args), do: {:ok, plugin.id}

  defp kv("get", scope, %{"key" => key}) when is_binary(key), do: {:ok, Storage.get(scope, key)}
  defp kv("set", scope, %{"key" => key} = args), do: ok(Storage.put(scope, key, args["value"]))

  defp kv("delete", scope, %{"key" => key}) when is_binary(key),
    do: ok(Storage.delete(scope, key))

  defp kv("list", scope, args), do: {:ok, Storage.list(scope, to_string(args["prefix"] || ""))}
  defp kv(op, _scope, _args), do: {:error, "invalid arguments for kv.#{op}"}

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
