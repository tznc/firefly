defmodule FirestormWeb.Drafts do
  @moduledoc """
  Server-side composer drafts. The composers (new thread, reply, edit)
  save what's typed as it changes (debounced in the browser, and flushed
  when the field loses focus, e.g. on following a link away), restore it
  when they open again, and drop it once the post is sent or the user
  discards it. A draft is identified by its context:

    * `{:new_thread, category}` - a new thread in that category
    * `{:reply, thread}` - a reply to that thread
    * `{:edit, post}` - an edit of that post

  Drafts are only ever read by their owner (every function takes the
  user). A user keeps at most `max_drafts/0`, and a draft's body is capped
  like a post's (`Post.max_body_length/0`). They're in the account export
  and go with the account.
  """

  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Forums.{Category, Draft, Policy, Post, Thread, User}

  @max_drafts 50

  @doc "How many drafts a user may keep."
  def max_drafts, do: @max_drafts

  @doc "The user's draft for `context`, or nil."
  def get(%User{id: user_id}, context),
    do: Repo.get_by(Draft, user_id: user_id, key: key(context))

  @doc """
  Saves the user's draft for `context` from `attrs` (`title`, `tags`,
  `body`; string or atom keys). A blank draft is deleted instead
  (`{:ok, nil}`). `{:error, :too_many}` when the user already has
  `max_drafts/0` others.
  """
  def save(%User{} = user, context, attrs) do
    changeset = Draft.changeset(new(user, context), attrs)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      Draft.blank?(Ecto.Changeset.apply_changes(changeset)) ->
        :ok = discard(user, context)
        {:ok, nil}

      too_many?(user, context) ->
        {:error, :too_many}

      true ->
        Repo.insert(changeset,
          on_conflict: {:replace, [:title, :tags, :body, :updated_at]},
          conflict_target: [:user_id, :key],
          returning: true
        )
    end
  end

  defp too_many?(user, context) do
    key = key(context)

    Draft
    |> where([d], d.user_id == ^user.id and d.key != ^key)
    |> Repo.aggregate(:count) >= @max_drafts
  end

  defp new(user, {:new_thread, %Category{id: id}} = context),
    do: %Draft{user_id: user.id, key: key(context), kind: "new_thread", category_id: id}

  defp new(user, {:reply, %Thread{id: id}} = context),
    do: %Draft{user_id: user.id, key: key(context), kind: "reply", thread_id: id}

  defp new(user, {:edit, %Post{id: id}} = context),
    do: %Draft{user_id: user.id, key: key(context), kind: "edit", post_id: id}

  defp key({:new_thread, %Category{id: id}}), do: "new_thread:#{id}"
  defp key({:reply, %Thread{id: id}}), do: "reply:#{id}"
  defp key({:edit, %Post{id: id}}), do: "edit:#{id}"

  @doc "Deletes the user's draft for `context`, if any."
  def discard(%User{id: user_id}, context) do
    Repo.delete_all(where(Draft, user_id: ^user_id, key: ^key(context)))
    :ok
  end

  @doc "Deletes one of the user's drafts by id (anyone else's is left alone)."
  def delete(%User{id: user_id}, id) do
    Repo.delete_all(where(Draft, user_id: ^user_id, id: ^id))
    :ok
  end

  @doc """
  The user's drafts they can still resume, most recently saved first, with
  what they're about loaded (`category`; `thread` with its category; `post`
  with its thread): drafts for threads or categories the user may no longer
  read, and edits of deleted posts, are left out.
  """
  def list(%User{} = user) do
    hidden_categories = Policy.hidden_category_ids(user)
    staff? = FirestormWeb.Forums.admin?(user)

    Draft
    |> where([d], d.user_id == ^user.id)
    |> join(:left, [d], p in Post, on: p.id == d.post_id)
    |> join(:left, [d, p], t in Thread, on: t.id == coalesce(d.thread_id, p.thread_id))
    |> where([d, p], is_nil(p.id) or is_nil(p.deleted_at))
    |> then(fn query ->
      if staff?,
        do: query,
        else:
          where(
            query,
            [d, p, t],
            coalesce(t.category_id, d.category_id) not in subquery(hidden_categories)
          )
    end)
    |> order_by([d], desc: d.updated_at, desc: d.id)
    |> preload([:category, thread: :category, post: :thread])
    |> Repo.all()
  end

  @doc "The user's drafts as plain data, for the account export."
  def export(%User{} = user) do
    Draft
    |> where([d], d.user_id == ^user.id)
    |> order_by(asc: :id)
    |> Repo.all()
    |> Enum.map(
      &Map.take(&1, [
        :kind,
        :category_id,
        :thread_id,
        :post_id,
        :title,
        :tags,
        :body,
        :inserted_at,
        :updated_at
      ])
    )
  end

  @doc "Deletes all of the user's drafts (account deletion)."
  def delete_all(%User{id: user_id}) do
    Repo.delete_all(where(Draft, user_id: ^user_id))
    :ok
  end

  @doc "Moves reply drafts from thread `from_id` to `to_id` (a merge), where there's no draft yet."
  def move_replies(from_id, to_id) do
    taken =
      from(d in Draft, where: d.thread_id == ^to_id and d.kind == "reply", select: d.user_id)

    Repo.update_all(
      from(d in Draft,
        where: d.thread_id == ^from_id and d.kind == "reply" and d.user_id not in subquery(taken)
      ),
      set: [thread_id: to_id, key: "reply:#{to_id}"]
    )

    :ok
  end

  def message(:too_many),
    do: "You have #{@max_drafts} drafts already: delete some to keep this one."
end
