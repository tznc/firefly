defmodule FirestormWeb.Forums.Subscriptions do
  @moduledoc """
  Notification levels for threads and categories:

    * `"watching"` - notified (in-app and by email) of every new post
    * `"tracking"` - notified in-app of every new post, no email
    * `"normal"` - not notified
    * `"muted"` - not notified, and hidden from the Latest/New/Unread lists

  A thread's level comes from the user's setting on the thread, falling back
  to their setting on its category, then on the parent category (for
  subcategories), then `"normal"`. Starting a thread sets it
  to watching and replying sets it to tracking, unless you've already chosen.
  """
  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Forums.{Category, CategoryWatch, Thread, User, Watch}

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

  @doc "The level that applies to the thread for the user (see the module doc)."
  def effective_thread_level(nil, _thread), do: "normal"

  def effective_thread_level(%User{} = user, %Thread{} = thread) do
    thread_level(user, thread) ||
      effective_category_level(user, Repo.get!(Category, thread.category_id))
  end

  @doc """
  The level a category's threads get when the user hasn't chosen one for the
  thread: their setting on the category, else on its parent, else `"normal"`.
  """
  def effective_category_level(nil, _category), do: "normal"

  def effective_category_level(%User{} = user, %Category{} = category) do
    category_level(user, category) ||
      (category.parent_id && category_level(user, %Category{id: category.parent_id})) ||
      "normal"
  end

  def set_thread_level(%User{} = user, %Thread{} = thread, level) when level in @levels do
    user |> thread_watch(thread, level) |> upsert(level)
  end

  def set_category_level(%User{} = user, %Category{} = category, level) when level in @levels do
    upsert(%CategoryWatch{user_id: user.id, assoc_id: category.id, level: level}, level)
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
    category = Repo.get!(Category, thread.category_id)

    # The parent's levels apply unless the category's own say otherwise.
    category_levels =
      Map.merge(
        category_watch_levels(category.parent_id),
        category_watch_levels(category.id)
      )

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

  defp category_watch_levels(nil), do: %{}

  defp category_watch_levels(category_id) do
    CategoryWatch
    |> where([w], w.assoc_id == ^category_id)
    |> select([w], {w.user_id, w.level})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Ids of threads that are muted for the user: directly, or via their category
  or its parent (when nothing more specific was chosen).
  """
  def muted_thread_ids(%User{id: user_id}) do
    muted_directly =
      from(w in thread_watches(),
        where: w.user_id == ^user_id and w.level == "muted",
        select: w.assoc_id
      )

    muted_by_category =
      from(t in Thread,
        join: cat in Category,
        on: cat.id == t.category_id,
        left_join: w in "forums_threads_watches",
        on: w.assoc_id == t.id and w.user_id == ^user_id,
        left_join: c in CategoryWatch,
        on: c.assoc_id == t.category_id and c.user_id == ^user_id,
        left_join: pc in CategoryWatch,
        on: pc.assoc_id == cat.parent_id and pc.user_id == ^user_id,
        where: is_nil(w.id) and coalesce(c.level, pc.level) == "muted",
        select: t.id
      )

    union_all(muted_directly, ^muted_by_category)
  end

  @doc "Threads the user is watching (by their own choice on the thread)."
  def watched_thread_ids(%User{id: user_id}) do
    from(w in thread_watches(),
      where: w.user_id == ^user_id and w.level == "watching",
      select: w.assoc_id
    )
  end
end
