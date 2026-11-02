defmodule FirestormWeb.Plugins.Events do
  @moduledoc """
  Events plugins can subscribe to (manifest `events`, delivered to their
  `handle_event` hook as `%{"event" => name, "data" => data}`):

    * `post_created`, `post_edited` - `%{post, thread}` (a reply; a new
      thread's first post comes with `thread_created`)
    * `post_deleted` - `%{post_id, thread_id}`
    * `thread_created` - `%{thread, post}` (its first post)
    * `user_registered` - `%{user}` (`id`, `username`)
    * `flag_raised` - `%{post_id, thread_id, reason}` (needs the `flag` permission)
    * `post_liked` - `%{post_id, thread_id, user_id}`
    * `solved` - `%{thread_id, post_id}` (an answer was accepted)
    * `poll_closed` - `%{poll_id, post_id, thread_id}`

  where a post is `%{id, thread_id, user_id, author, body, url}` and a
  thread `%{id, title, category_id, url}`.

  Like everything plugins see, events are only about content anonymous
  visitors can read: nothing from private categories, nor about posts
  awaiting approval. A plugin isn't told about what its own bot did, so it
  can't loop on its own replies.

  Delivery is asynchronous and durable: `emit/3` queues a row per
  subscriber (`FirestormWeb.Plugins.QueuedEvent`) in the caller's
  transaction, and `FirestormWeb.Plugins.Queue` delivers them. A failed
  delivery is retried after 30 seconds, 2 minutes, 8 minutes and 32 minutes,
  then dropped (and logged). Events for a plugin that's inactive when they
  come due are dropped.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Plugins, Repo}
  alias FirestormWeb.Forums.{Post, Thread, User}
  alias FirestormWeb.Plugin.Runner
  alias FirestormWeb.Plugins.{Health, QueuedEvent}
  alias FirestormWeb.Web.Paths

  @names ~w(post_created post_edited post_deleted thread_created user_registered flag_raised
            post_liked solved poll_closed)
  @max_attempts 5
  # How long a delivery in progress holds its row before another node may
  # take it.
  @lease 300

  @doc "Every event name."
  def names, do: @names

  @doc """
  Queues `event` for the plugins subscribed to it. `data` is the payload or
  a function building it (only called if anyone listens). Options:
  `:thread` (the content's thread, or a function loading it: nothing is
  sent unless anonymous visitors can read it), `:post` (likewise: not while it awaits approval),
  `:actor` (the user who did it).
  """
  def emit(event, data, opts \\ []) when event in @names do
    actor = opts[:actor]

    subscribers =
      for plugin <- Plugins.implementing("handle_event"),
          event in plugin.manifest.events,
          not bot_of?(actor, plugin.id),
          do: plugin

    if subscribers != [] and public?(opts[:post], opts[:thread]) do
      payload = if is_function(data, 0), do: data.(), else: data
      now = DateTime.utc_now()

      rows =
        for plugin <- subscribers do
          %{
            plugin_id: plugin.id,
            event: event,
            payload: payload,
            run_at: now,
            inserted_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now()
          }
        end

      Repo.insert_all(QueuedEvent, rows)
      Plugins.Queue.kick()
    end

    :ok
  end

  defp bot_of?(%User{plugin_bot: id}, id) when is_binary(id), do: true
  defp bot_of?(_actor, _id), do: false

  defp public?(post, thread) do
    thread = if is_function(thread, 0), do: thread.(), else: thread

    (is_nil(post) or Post.readable_by?(post, nil)) and
      (is_nil(thread) or Bodyguard.permit?(Forums, :view_thread, nil, thread))
  end

  @doc "A post as events describe it."
  def post_data(%Post{} = post, %Thread{} = thread) do
    post = Repo.preload(post, :user)

    %{
      id: post.id,
      thread_id: thread.id,
      user_id: post.user_id,
      author: post.user && post.user.username,
      body: post.body,
      url: "#{Paths.thread_url(thread)}#post-#{post.id}"
    }
  end

  @doc "A thread as events describe it."
  def thread_data(%Thread{} = thread),
    do: %{
      id: thread.id,
      title: thread.title,
      category_id: thread.category_id,
      url: Paths.thread_url(thread)
    }

  @doc "Delivers the events due at `now`, one at a time. Returns how many were delivered."
  def deliver_due(now \\ DateTime.utc_now()), do: deliver_due(now, 0)

  defp deliver_due(now, count) do
    case claim(now) do
      nil -> count
      row -> deliver_due(now, count + deliver(row, now))
    end
  end

  defp claim(now) do
    {:ok, row} =
      Repo.transact(fn ->
        row =
          QueuedEvent
          |> where([e], e.run_at <= ^now)
          |> order_by([e], asc: e.run_at, asc: e.id)
          |> limit(1)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> Repo.one()

        {:ok, row && Repo.update!(Ecto.Changeset.change(row, run_at: DateTime.add(now, @lease)))}
      end)

    row
  end

  defp deliver(row, now) do
    with %{} = plugin <- Plugins.get_active(row.plugin_id),
         {:ok, _} <-
           Runner.invoke(plugin, "handle_event", [%{"event" => row.event, "data" => row.payload}]) do
      Repo.delete!(row)
      1
    else
      nil ->
        Repo.delete!(row)
        0

      {:error, reason} ->
        retry(row, reason, now)
        0
    end
  end

  defp retry(row, reason, now) do
    attempts = row.attempts + 1
    message = describe(reason)

    if attempts >= @max_attempts do
      Repo.delete!(row)

      Health.log_error(
        row.plugin_id,
        "handle_event",
        :gave_up,
        "Dropped #{row.event} after #{attempts} attempts; the last: #{message}"
      )
    else
      Repo.update!(
        Ecto.Changeset.change(row,
          attempts: attempts,
          last_error: message,
          run_at: DateTime.add(now, 30 * 4 ** (attempts - 1))
        )
      )
    end
  end

  defp describe({kind, message}), do: "#{kind}: #{message}"
  defp describe(reason), do: to_string(inspect(reason))

  @doc "Drops `plugin_id`'s queued events (on uninstall)."
  def clear(plugin_id), do: Repo.delete_all(where(QueuedEvent, plugin_id: ^plugin_id))
end
