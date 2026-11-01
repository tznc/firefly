defmodule FirestormWeb.Forums.Subscriptions do
  @moduledoc """
  Notification levels for threads, categories and tags:

    * `"watching"` - notified (in-app and by email) of every new post
    * `"tracking"` - notified in-app of every new post, no email
    * `"normal"` - not notified
    * `"muted"` - not notified, and hidden from the Latest/New/Unread lists

  A thread's level is the user's setting on the thread, if they chose one.
  Otherwise it combines their settings on its category and its tags: muted if
  any of them is muted (muting is an explicit "don't show me this"), else the
  most attentive of them (watching over tracking over normal), else
  `"normal"`. So watching a tag notifies you of its threads in any category,
  and muting a tag hides its threads even in a watched category, unless you
  set a level on the thread itself.

  Starting a thread sets it to watching and replying sets it to tracking,
  unless you've already chosen.
  """
  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Forums.{Category, CategoryWatch, Tag, TagWatch, Thread, User, Watch}

  @levels ~w(watching tracking normal muted)
  @notified ~w(watching tracking)

  def levels, do: @levels

  defp thread_watches, do: {"forums_threads_watches", Watch}

  @doc "The level the user chose for the thread, or nil."
  def thread_level(nil, _thread), do: nil

  def thread_level(%User{id: user_id}, %Thread{id: thread_id}) do
    thread_watches()
    |> where([w], w.user_id == ^user_id and w.assoc_id == ^thread_id)
    |> select([w], w.level)
    |> Repo.one()
  end

  @doc "The level the user chose for the category, or nil."
  def category_level(nil, _category), do: nil

  def category_level(%User{id: user_id}, %Category{id: category_id}) do
    CategoryWatch
    |> where([w], w.user_id == ^user_id and w.assoc_id == ^category_id)
    |> select([w], w.level)
    |> Repo.one()
  end

  @doc "The level the user chose for the tag, or nil."
  def tag_level(nil, _tag), do: nil

  def tag_level(%User{id: user_id}, %Tag{id: tag_id}) do
    TagWatch
    |> where([w], w.user_id == ^user_id and w.assoc_id == ^tag_id)
    |> select([w], w.level)
    |> Repo.one()
  end

  @doc "The level that applies to the thread for the user (see the module doc)."
  def effective_thread_level(nil, _thread), do: "normal"

  def effective_thread_level(%User{} = user, %Thread{} = thread),
    do: thread_level(user, thread) || inherited_level(user, thread)

  @doc """
  The level the thread gets from its category and tags when the user sets
  none on the thread itself.
  """
  def inherited_level(nil, _thread), do: "normal"

  def inherited_level(%User{id: user_id} = user, %Thread{} = thread) do
    tag_levels =
      TagWatch
      |> join(:inner, [w], tt in "forums_threads_tags", on: tt.tag_id == w.assoc_id)
      |> where([w, tt], w.user_id == ^user_id and tt.thread_id == ^thread.id)
      |> select([w], w.level)
      |> Repo.all()

    combine([category_level(user, %Category{id: thread.category_id}) | tag_levels]) || "normal"
  end

  # Category and tag levels: muted wins, then the most attentive (see the
  # module doc). Nil if none was set.
  defp combine(levels) do
    levels = Enum.reject(levels, &is_nil/1)

    cond do
      "muted" in levels -> "muted"
      "watching" in levels -> "watching"
      "tracking" in levels -> "tracking"
      levels != [] -> "normal"
      true -> nil
    end
  end

  def set_thread_level(%User{} = user, %Thread{} = thread, level) when level in @levels do
    user |> thread_watch(thread, level) |> upsert(level)
  end

  def set_category_level(%User{} = user, %Category{} = category, level) when level in @levels do
    upsert(%CategoryWatch{user_id: user.id, assoc_id: category.id, level: level}, level)
  end

  def set_tag_level(%User{} = user, %Tag{} = tag, level) when level in @levels do
    upsert(%TagWatch{user_id: user.id, assoc_id: tag.id, level: level}, level)
  end

  @doc "Sets the thread level only if the user hasn't chosen one."
  def ensure_thread_level(%User{} = user, %Thread{} = thread, level) when level in @levels do
    user
    |> thread_watch(thread, level)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :assoc_id])
  end

  defp thread_watch(user, thread, level) do
    Ecto.put_meta(%Watch{user_id: user.id, assoc_id: thread.id, level: level},
      source: "forums_threads_watches"
    )
  end

  defp upsert(struct, level) do
    Repo.insert(struct,
      on_conflict: [set: [level: level, updated_at: NaiveDateTime.utc_now()]],
      conflict_target: [:user_id, :assoc_id],
      returning: true
    )
  end

  @doc """
  Users to notify about activity in the thread, with their effective level
  (watching or tracking).
  """
  def subscribers(%Thread{} = thread) do
    tag_levels =
      TagWatch
      |> join(:inner, [w], tt in "forums_threads_tags", on: tt.tag_id == w.assoc_id)
      |> where([w, tt], tt.thread_id == ^thread.id)
      |> select([w], {w.user_id, w.level})

    category_levels =
      CategoryWatch
      |> where([w], w.assoc_id == ^thread.category_id)
      |> select([w], {w.user_id, w.level})
      |> union_all(^tag_levels)
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {user_id, levels} -> {user_id, combine(levels)} end)

    thread_levels =
      thread_watches()
      |> where([w], w.assoc_id == ^thread.id)
      |> select([w], {w.user_id, w.level})
      |> Repo.all()
      |> Map.new()

    levels =
      category_levels
      |> Map.merge(thread_levels)
      |> Map.filter(fn {_user_id, level} -> level in @notified end)

    User
    |> where([u], u.id in ^Map.keys(levels))
    |> Repo.all()
    |> Enum.map(&{&1, Map.fetch!(levels, &1.id)})
  end

  @doc """
  Ids of threads that are muted for the user: directly, or via their category
  or one of their tags when the user set no level on the thread.
  """
  def muted_thread_ids(%User{id: user_id}) do
    muted_directly =
      from(w in thread_watches(),
        where: w.user_id == ^user_id and w.level == "muted",
        select: w.assoc_id
      )

    chosen = from(w in thread_watches(), where: w.user_id == ^user_id, select: w.assoc_id)

    muted_by_category =
      from(t in Thread,
        join: c in CategoryWatch,
        on: c.assoc_id == t.category_id and c.user_id == ^user_id and c.level == "muted",
        where: t.id not in subquery(chosen),
        select: t.id
      )

    muted_by_tag =
      from(tt in "forums_threads_tags",
        join: w in TagWatch,
        on: w.assoc_id == tt.tag_id and w.user_id == ^user_id and w.level == "muted",
        where: tt.thread_id not in subquery(chosen),
        select: tt.thread_id
      )

    muted_directly |> union_all(^muted_by_category) |> union_all(^muted_by_tag)
  end

  @doc "Threads the user is watching (by their own choice on the thread)."
  def watched_thread_ids(%User{id: user_id}) do
    from(w in thread_watches(),
      where: w.user_id == ^user_id and w.level == "watching",
      select: w.assoc_id
    )
  end
end
