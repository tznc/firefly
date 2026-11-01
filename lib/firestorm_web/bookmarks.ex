defmodule FirestormWeb.Bookmarks do
  @moduledoc """
  Bookmarked posts, with an optional note and an optional reminder.

  A user may bookmark any post they can read (`Post.readable_by?/2` and the
  `:view_thread` policy). Bookmarks are private, like drafts: only their
  owner reads or changes them (every function takes the user), and a
  silenced member may still bookmark, as it's reading, not writing (see
  `FirestormWeb.Penalties`). Bookmarks follow their post (they hold only its
  id), so a merge or split carries them along.

  A post that becomes unreadable to its bookmarker (deleted, hidden after
  flags, its category restricted) hides the bookmark: it's left out of
  `list/1` and can't be changed, and its reminder, when due, is dropped
  without a notification. The bookmark comes back if the post does.

  Reminders live in the database, so they survive restarts:
  `FirestormWeb.TopicTimers.Scheduler` runs `run_due/1`, which fires each
  due reminder exactly once: the bookmark is locked (`SKIP LOCKED`, so two
  nodes never take the same one), and its `remind_at` cleared in the same
  transaction that inserts the `bookmark_reminder` notification.

  Bookmarks are in the account export and go with the account.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.{Bookmark, Notification, Policy, Post, Thread, User}
  alias FirestormWeb.Web.Paths

  @presets [
    {"Later today", "later_today"},
    {"Tomorrow", "tomorrow"},
    {"Next week", "next_week"}
  ]

  @doc "Reminder presets, as select options."
  def presets, do: @presets

  @doc """
  Bookmarks `post` for `user` (a no-op if it already is). `{:error,
  :not_found}` if the user can't read it.
  """
  def bookmark(%User{} = user, %Post{} = post) do
    if readable?(user, post) do
      Repo.insert(%Bookmark{user_id: user.id, post_id: post.id},
        on_conflict: :nothing,
        conflict_target: [:user_id, :post_id]
      )

      {:ok, Repo.get_by!(Bookmark, user_id: user.id, post_id: post.id)}
    else
      {:error, :not_found}
    end
  end

  @doc "Removes `user`'s bookmark of `post`, if any."
  def unbookmark(%User{id: user_id}, %Post{id: post_id}) do
    Repo.delete_all(where(Bookmark, user_id: ^user_id, post_id: ^post_id))
    :ok
  end

  @doc "Whether `user` may read `post` where it is now (so bookmark it)."
  def readable?(%User{} = user, %Post{} = post) do
    thread = Repo.get(Thread, post.thread_id)

    thread != nil and Post.readable_by?(post, user) and
      Bodyguard.permit?(Forums, :view_thread, user, thread)
  end

  @doc "The user's bookmark of `post`, or nil."
  def get_for_post(%User{id: user_id}, %Post{id: post_id}),
    do: Repo.get_by(Bookmark, user_id: user_id, post_id: post_id)

  @doc """
  One of the user's bookmarks by id, with its post and thread, or nil
  (someone else's, or hidden: see the module doc).
  """
  def get(%User{} = user, id) do
    user
    |> visible()
    |> where([b], b.id == ^id)
    |> preload([b, post: p, thread: t], post: {p, thread: t})
    |> Repo.one()
  end

  @doc "The ids of `posts` the user bookmarked, as a `MapSet` (empty for visitors)."
  def bookmarked_ids(nil, _posts), do: MapSet.new()

  def bookmarked_ids(%User{id: user_id}, posts) do
    ids = Enum.map(posts, & &1.id)

    Bookmark
    |> where([b], b.user_id == ^user_id and b.post_id in ^ids)
    |> select([b], b.post_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The user's bookmarks they can still read (see the module doc), pending
  reminders first (soonest first), then the newest. Each has its post, with
  its author and its thread's category, loaded.
  """
  def list(%User{} = user) do
    user
    |> visible()
    |> order_by([b], asc_nulls_last: b.remind_at, desc: b.inserted_at, desc: b.id)
    |> preload([b, post: p, thread: t], post: {p, [:user, thread: {t, :category}]})
    |> Repo.all()
  end

  # The user's bookmarks of posts they may read: `Post.readable_by?/2` and
  # `Policy.readable_threads/2` as a query. Binds `:post` and `:thread`.
  defp visible(%User{} = user) do
    Bookmark
    |> where([b], b.user_id == ^user.id)
    |> join(:inner, [b], p in assoc(b, :post), as: :post)
    |> join(:inner, [post: p], t in assoc(p, :thread), as: :thread)
    |> Policy.readable_threads(user)
    |> where(^readable_post(user))
  end

  defp readable_post(user) do
    if Forums.admin?(user),
      do: dynamic(true),
      else:
        dynamic(
          [post: p],
          is_nil(p.deleted_at) and
            ((is_nil(p.hidden_at) and is_nil(p.queued_at)) or p.user_id == ^user.id)
        )
  end

  @doc "A changeset for the bookmark form."
  def change(%Bookmark{} = bookmark, attrs \\ %{}), do: Bookmark.changeset(bookmark, attrs)

  @doc """
  Updates the note and reminder of one of the user's bookmarks (by id) from
  `attrs`: `"note"`, and `"reminder"`, one of `presets/0`'s values,
  `"custom"` (then `"custom_at"`, a local `datetime-local` value) or `""`
  (no reminder). `offset` is the browser's `getTimezoneOffset()` in
  minutes, for the presets and custom times to mean local time.
  """
  def update(%User{} = user, id, attrs, offset \\ 0) do
    case get(user, id) do
      nil ->
        {:error, :not_found}

      bookmark ->
        at = remind_at(attrs["reminder"], attrs["custom_at"], offset)

        bookmark
        |> Bookmark.changeset(%{note: attrs["note"], remind_at: at})
        |> require_custom_time(attrs["reminder"], at)
        |> Repo.update()
    end
  end

  defp require_custom_time(changeset, "custom", nil),
    do: Ecto.Changeset.add_error(changeset, :remind_at, "needs a date and time")

  defp require_custom_time(changeset, _choice, _at), do: changeset

  @doc """
  When a reminder `choice` (see `update/4`) falls, from `now`, in the local
  time `offset` minutes behind UTC: "later today" is in three hours,
  "tomorrow" 8am tomorrow, "next week" 8am next Monday. Nil for no
  reminder, or a custom time that doesn't parse.
  """
  def remind_at(choice, custom, offset, now \\ DateTime.utc_now(:second))

  def remind_at("later_today", _custom, _offset, now), do: DateTime.add(now, 3, :hour)

  def remind_at("tomorrow", _custom, offset, now),
    do: local_morning(now, offset, &Date.add(&1, 1))

  def remind_at("next_week", _custom, offset, now),
    do: local_morning(now, offset, &Date.add(&1, 8 - Date.day_of_week(&1)))

  def remind_at("custom", custom, offset, _now) when is_binary(custom) do
    # datetime-local values have no seconds; with them they parse too.
    case NaiveDateTime.from_iso8601(
           if(byte_size(custom) == 16, do: custom <> ":00", else: custom)
         ) do
      {:ok, local} -> from_local(local, offset)
      {:error, _} -> nil
    end
  end

  def remind_at(_none, _custom, _offset, _now), do: nil

  defp local_morning(now, offset, day_after) do
    today = now |> DateTime.add(-offset, :minute) |> DateTime.to_date()
    today |> day_after.() |> NaiveDateTime.new!(~T[08:00:00]) |> from_local(offset)
  end

  defp from_local(local, offset) do
    local |> NaiveDateTime.add(offset, :minute) |> DateTime.from_naive!("Etc/UTC")
  end

  @doc "`at` (UTC) as a local `datetime-local` value, `offset` minutes behind UTC."
  def to_local_input(nil, _offset), do: nil

  def to_local_input(%DateTime{} = at, offset) do
    at
    |> DateTime.add(-offset, :minute)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> binary_part(0, 16)
  end

  @doc "Clears the reminder of one of the user's bookmarks (by id)."
  def clear_reminder(%User{id: user_id}, id) do
    Repo.update_all(where(Bookmark, user_id: ^user_id, id: ^id), set: [remind_at: nil])
    :ok
  end

  @doc "Deletes one of the user's bookmarks by id (anyone else's is left alone)."
  def delete(%User{id: user_id}, id) do
    Repo.delete_all(where(Bookmark, user_id: ^user_id, id: ^id))
    :ok
  end

  @doc """
  Fires every reminder due at `now`, one transaction each. Returns how many
  notified (dropped ones, for posts the user can't read, don't count).
  """
  def run_due(now \\ DateTime.utc_now()), do: run_due(now, 0)

  defp run_due(now, count) do
    case fire_next(now) do
      {:ok, :none} ->
        count

      {:ok, nil} ->
        run_due(now, count)

      {:ok, user_id} ->
        Forums.notifications_changed(user_id)
        run_due(now, count + 1)
    end
  end

  # Takes the next due reminder and clears it; notifies its user if they
  # may still read the post. Returns the notified user's id (nil: dropped).
  defp fire_next(now) do
    Repo.transact(fn ->
      Bookmark
      |> where([b], b.remind_at <= ^now)
      |> order_by([b], asc: b.remind_at, asc: b.id)
      |> limit(1)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.one()
      |> case do
        nil ->
          {:ok, :none}

        bookmark ->
          bookmark = Repo.preload(bookmark, [:user, post: :thread])
          Repo.update!(Ecto.Changeset.change(bookmark, remind_at: nil))
          {:ok, remind(bookmark)}
      end
    end)
  end

  defp remind(%Bookmark{user: user, post: post} = bookmark) do
    if readable?(user, post) do
      %Notification{}
      |> Notification.changeset(%{
        user_id: user.id,
        kind: "bookmark_reminder",
        subject: "Reminder: your bookmark in \"#{post.thread.title}\"",
        body: bookmark.note || post.body,
        url: "#{Paths.thread_url(post.thread)}#post-#{post.id}",
        thread_id: post.thread_id,
        post_id: post.id
      })
      |> Repo.insert!()

      user.id
    end
  end

  @doc "The user's bookmarks as plain data, for the account export."
  def export(%User{} = user) do
    Bookmark
    |> where([b], b.user_id == ^user.id)
    |> join(:inner, [b], p in assoc(b, :post))
    |> order_by(asc: :id)
    |> select([b, p], %{
      post_id: b.post_id,
      thread_id: p.thread_id,
      note: b.note,
      remind_at: b.remind_at,
      inserted_at: b.inserted_at
    })
    |> Repo.all()
  end

  def message(:not_found), do: "That post is no longer available."
end
