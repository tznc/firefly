defmodule FirestormWeb.TopicTools do
  @moduledoc """
  Admin tools that move posts between threads (the `:moderate_thread`
  policy, like pin and close):

    * `merge/3`: every post of a thread moves into another. The source
      stays behind as a closed stub with `merged_into_id` set: its pages
      redirect to the target and no list shows it.
    * `split/4`: chosen replies (never the first post) move to a new thread,
      with a title and category, or into an existing one. Their authors are
      told where their posts went.

  Moved posts keep their place in time among the target's posts (threads
  are ordered by `inserted_at`), except that the target's first post stays
  first: a moved post older than it is placed just after it.

  Post counts and last activity are worked out from the posts, so they
  follow by themselves. The rest is moved over in the same transaction:
  reply drafts (on a merge), read positions (see `rebase_reads/3`), notification levels (see
  `FirestormWeb.Forums.Subscriptions.copy_thread_levels/3`), the
  notifications about the moved posts (now pointing at the target), and a
  staff log entry. Bookmarks follow their posts by themselves; an accepted
  answer that moves is unaccepted (see `FirestormWeb.Solved`). Open pages
  are told once it has committed.
  """

  import Ecto.Query

  alias FirestormWeb.{Drafts, Forums, Repo, Solved, StaffLog}
  alias FirestormWeb.Forums.{Category, Notification, Policy, Post, Subscriptions}
  alias FirestormWeb.Forums.{Thread, ThreadRead, User}
  alias FirestormWeb.Web.Paths

  @doc """
  Merges `source` into `target` as `actor`. Returns `{:ok, target}`, or
  `{:error, reason}` (see `message/1`).
  """
  def merge(%Thread{} = source, %Thread{} = target, %User{} = actor) do
    result =
      Repo.transact(fn ->
        [source, target] = lock_threads([source.id, target.id])

        with :ok <- check_target(source, target) do
          moved_ids = Repo.all(from(p in Post, where: p.thread_id == ^source.id, select: p.id))

          rebase_reads(target, source.id, moved_ids)
          Repo.delete_all(from(r in ThreadRead, where: r.thread_id == ^source.id))
          move_posts(moved_ids, target)
          Subscriptions.copy_thread_levels(source.id, target.id, :combine)
          Drafts.move_replies(source.id, target.id)
          notified = repoint_notifications(where(Notification, thread_id: ^source.id), target)

          # The stub keeps its title (for the log and old links) but not
          # its tags: it's on no list, so it would only inflate tag counts.
          Repo.delete_all(from(tt in "forums_threads_tags", where: tt.thread_id == ^source.id))

          # Stubs of the source now point straight at the target.
          Repo.update_all(where(Thread, merged_into_id: ^source.id),
            set: [merged_into_id: target.id]
          )

          stub =
            source
            |> Ecto.Changeset.change(
              merged_into_id: target.id,
              closed_at: DateTime.utc_now(:second)
            )
            |> Repo.update!()

          StaffLog.record(actor, "thread.merge", stub, %{
            title: source.title,
            into: target.title,
            posts: length(moved_ids)
          })

          {:ok, {stub, target, notified}}
        end
      end)

    with {:ok, {stub, target, notified}} <- result do
      Enum.each(notified, &Forums.notifications_changed/1)
      Forums.thread_changed(:thread_updated, stub)
      Forums.thread_changed(:thread_updated, target)
      {:ok, target}
    end
  end

  @doc """
  Moves the posts with `post_ids` out of `source` as `actor`, to
  `{:new, %{"title" => title, "category_id" => id}}` (a new thread) or
  `{:existing, thread}`. Returns `{:ok, target}`, or `{:error, reason}` (an
  invalid changeset for a new thread's title; see `message/1` otherwise).
  """
  def split(%Thread{} = source, post_ids, destination, %User{} = actor) do
    post_ids = for id <- List.wrap(post_ids), {id, ""} <- [Integer.parse(to_string(id))], do: id

    result =
      Repo.transact(fn ->
        with {:ok, source, posts} <- lock_split_source(source, post_ids),
             {:ok, target, new?} <- split_target(source, destination, posts) do
          moved_ids = Enum.map(posts, & &1.id)

          rebase_reads(target, source.id, moved_ids)
          move_posts(moved_ids, target)
          Subscriptions.copy_thread_levels(source.id, target.id, :keep)

          notified =
            repoint_notifications(where(Notification, [n], n.post_id in ^moved_ids), target)

          StaffLog.record(actor, "thread.split", source, %{
            title: source.title,
            to: target.title,
            new_thread: new?,
            posts: length(moved_ids)
          })

          # Reloaded: the move may have unaccepted its answer.
          {:ok, {Repo.reload!(source), target, new?, posts, notified}}
        end
      end)

    with {:ok, {source, target, new?, posts, notified}} <- result do
      Enum.each(notified, &Forums.notifications_changed/1)
      notify_authors(posts, target, actor)
      Forums.thread_changed(:thread_updated, source)
      Forums.thread_changed(if(new?, do: :thread_created, else: :thread_updated), target)
      {:ok, target}
    end
  end

  @doc """
  Sets `thread`'s slow mode as `actor`: members may reply at most once per
  `seconds` (nil or 0: off). Enforced by `FirestormWeb.Posting.check/2`.
  """
  def set_slow_mode(%Thread{} = thread, seconds, %User{} = actor) do
    seconds = if seconds in [0, "0", ""], do: nil, else: seconds
    changeset = Thread.slow_mode_changeset(thread, %{slow_mode_seconds: seconds})

    result =
      Repo.transact(fn ->
        with {:ok, updated} <- Repo.update(changeset) do
          log_slow_mode(actor, thread, updated)
          {:ok, updated}
        end
      end)

    with {:ok, updated} <- result do
      Forums.thread_changed(:thread_updated, updated)
      {:ok, updated}
    end
  end

  defp log_slow_mode(_actor, %{slow_mode_seconds: same}, %{slow_mode_seconds: same}), do: nil

  defp log_slow_mode(actor, before, updated) do
    StaffLog.record(actor, "thread.slow_mode", updated, %{
      title: updated.title,
      seconds: %{before: before.slow_mode_seconds, after: updated.slow_mode_seconds}
    })
  end

  def message(:same_thread), do: "Pick a different thread."
  def message(:merged), do: "That thread was merged into another one: pick that one."
  def message(:no_thread), do: "No such thread."
  def message(:no_posts), do: "Select at least one reply."
  def message(:first_post), do: "The first post can't be moved: merge the thread instead."
  def message(:deleted_first), do: "A new thread can't start with a deleted post."
  def message(:no_category), do: "That category no longer exists."

  # Locked in id order, so two moves between the same threads can't deadlock.
  defp lock_threads(ids) do
    threads =
      Thread
      |> where([t], t.id in ^ids)
      |> order_by(:id)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(ids, &Map.fetch!(threads, &1))
  end

  defp check_target(%Thread{id: id}, %Thread{id: id}), do: {:error, :same_thread}

  defp check_target(source, target) do
    if Thread.merged?(source) or Thread.merged?(target), do: {:error, :merged}, else: :ok
  end

  defp lock_split_source(source, post_ids) do
    [source] = lock_threads([source.id])

    posts =
      Post
      |> where([p], p.thread_id == ^source.id and p.id in ^post_ids)
      |> order_by([p], asc: p.inserted_at, asc: p.id)
      |> Repo.all()

    cond do
      Thread.merged?(source) -> {:error, :merged}
      posts == [] or length(posts) != length(Enum.uniq(post_ids)) -> {:error, :no_posts}
      # In posting order, so the first post would be the head.
      Forums.first_post?(hd(posts)) -> {:error, :first_post}
      true -> {:ok, source, posts}
    end
  end

  defp split_target(source, {:existing, %Thread{} = target}, _posts) do
    [target] = lock_threads([target.id])
    with :ok <- check_target(source, target), do: {:ok, target, false}
  end

  defp split_target(_source, {:new, attrs}, [first | _posts]) do
    with :ok <- if(Post.deleted?(first), do: {:error, :deleted_first}, else: :ok),
         %Category{} = category <- category(attrs["category_id"]) || {:error, :no_category},
         {:ok, thread} <-
           %Thread{}
           |> Thread.changeset(%{title: attrs["title"], category_id: category.id})
           |> Repo.insert() do
      {:ok, thread, true}
    end
  end

  defp category(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get(Category, id)
      _invalid -> nil
    end
  end

  # Moves the posts into `target`, keeping its first post first: moved posts
  # older than it are placed just after it, in their order.
  defp move_posts(post_ids, target) do
    # An accepted answer moving away is no longer its thread's answer (nor
    # the target's: that thread's author didn't pick it).
    :ok = Solved.clear(post_ids)

    first =
      Post
      |> where([p], p.thread_id == ^target.id)
      |> order_by([p], asc: p.inserted_at, asc: p.id)
      |> limit(1)
      |> Repo.one()

    if first do
      Post
      |> where([p], p.id in ^post_ids)
      |> where([p], p.inserted_at < ^first.inserted_at)
      |> order_by([p], asc: p.inserted_at, asc: p.id)
      |> Repo.all()
      |> Enum.with_index(1)
      |> Enum.each(fn {post, n} ->
        at = NaiveDateTime.add(first.inserted_at, n, :microsecond)
        Repo.update_all(where(Post, id: ^post.id), set: [inserted_at: at])
      end)
    end

    Repo.update_all(where(Post, [p], p.id in ^post_ids), set: [thread_id: target.id])
  end

  @doc """
  Read positions in `target` once the posts `moved_ids` (from thread
  `source_id`) join it. A position is one post id (everything up to it is
  read), so for each user who had opened either thread it becomes the
  furthest point up to which they had read everything, in both: just
  before the first post they hadn't seen, or the newest post if they had
  seen them all. So someone who read both threads to the end has the
  target read, and nobody has an unread post marked read. Runs before the
  posts move.
  """
  def rebase_reads(%Thread{id: target_id}, source_id, moved_ids) do
    published = fn query -> query |> Post.visible() |> select([p], p.id) |> Repo.all() end
    moved = published.(where(Post, [p], p.id in ^moved_ids))
    existing = published.(where(Post, [p], p.thread_id == ^target_id))

    reads =
      ThreadRead
      |> where([r], r.thread_id in ^[source_id, target_id])
      |> Repo.all()
      |> Enum.group_by(& &1.user_id, &{&1.thread_id, &1.last_read_post_id})
      |> Map.new(fn {user_id, positions} -> {user_id, Map.new(positions)} end)

    now = NaiveDateTime.utc_now()

    rows =
      for {user_id, positions} <- reads do
        %{
          user_id: user_id,
          thread_id: target_id,
          last_read_post_id:
            read_up_to(moved, positions[source_id], existing, positions[target_id]),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(ThreadRead, rows,
      on_conflict: {:replace, [:last_read_post_id, :updated_at]},
      conflict_target: [:user_id, :thread_id]
    )

    :ok
  end

  # Just before the first unread post of either, or the newest if none is.
  defp read_up_to(moved, source, existing, target) do
    case unread_after(moved, source) ++ unread_after(existing, target) do
      [] -> Enum.max(moved ++ existing, fn -> max(source || 0, target || 0) end)
      unread -> Enum.min(unread) - 1
    end
  end

  # Never opened: every post is unread.
  defp unread_after(ids, nil), do: ids
  defp unread_after(ids, position), do: Enum.filter(ids, &(&1 > position))

  # Points the notifications in `query` at `target` (their links too), so
  # opening it or reading the target reads them. Returns their users.
  defp repoint_notifications(query, target) do
    base = Paths.thread_url(target)

    {_count, user_ids} =
      query
      |> select([n], n.user_id)
      |> update([n],
        set: [
          thread_id: ^target.id,
          url: fragment("? || COALESCE('#post-' || ?::text, '')", ^base, n.post_id)
        ]
      )
      |> Repo.update_all([])

    Enum.uniq(user_ids)
  end

  # One in-app notification per author (not the admin who moved them), if
  # they may read where their posts went.
  defp notify_authors(posts, target, actor) do
    first_by_author = posts |> Enum.reverse() |> Map.new(&{&1.user_id, &1})
    authors = User |> where([u], u.id in ^Map.keys(first_by_author)) |> Repo.all()

    for author <- Policy.thread_readers(target, authors),
        author.id != actor.id and not User.deleted?(author) do
      post = first_by_author[author.id]

      Forums.notify(author, %{
        kind: "moved",
        subject: "Staff moved your post to \"#{target.title}\"",
        body: post.body,
        url: "#{Paths.thread_url(target)}#post-#{post.id}",
        thread_id: target.id,
        post_id: post.id
      })
    end

    :ok
  end
end
