defmodule FirestormWeb.StaffLog do
  @moduledoc """
  The staff log: an audit trail of every staff action, shown to admins at
  `/staff/log`.

  The context functions that perform staff actions (thread moderation, edits
  and deletions of other people's content, category changes) call
  `record/4` inside the action's transaction, so an action is logged if and
  only if it happened. Edits made in the Kaffy admin at `/admin` are logged
  by `FirestormWeb.Admin.Logged`. What members do to their own content is
  not staff action and isn't logged.
  """

  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Forums.{Category, Post, StaffAction, Thread, User}

  @actions ~w(
    thread.pin thread.unpin thread.close thread.open thread.archive thread.unarchive
    thread.move thread.edit thread.delete
    post.edit post.delete post.restore
    category.create category.update category.delete
    role.grant role.revoke
    user.silence user.unsilence user.suspend user.unsuspend
    setting.update
    admin.create admin.update admin.delete
  )

  @doc "Every action the log records, in display order."
  def actions, do: @actions

  @doc """
  Records that `actor` took `action` on `target` (a thread, post, category or
  user, or a `{type, id}` pair). `details` must be JSON-encodable; see
  `FirestormWeb.Forums.StaffAction`. Raises if the entry can't be saved, which
  rolls back the surrounding transaction. With no actor (seeds and scripts)
  nothing is recorded.
  """
  def record(actor, action, target, details \\ %{})

  def record(nil, _action, _target, _details), do: nil

  def record(%User{} = actor, action, target, details) when action in @actions do
    {type, id} = target_ref(target)

    Repo.insert!(%StaffAction{
      actor_id: actor.id,
      action: action,
      target_type: type,
      target_id: id,
      details: details
    })
  end

  defp target_ref(%Thread{id: id}), do: {"thread", id}
  defp target_ref(%Post{id: id}), do: {"post", id}
  defp target_ref(%Category{id: id}), do: {"category", id}
  defp target_ref(%User{id: id}), do: {"user", id}
  defp target_ref({type, id}) when is_binary(type), do: {type, id}

  @doc """
  The before/after values of the fields a changeset changes, for `details`
  (associations are left out). Values JSON can't hold are inspected.
  """
  def changes(%Ecto.Changeset{changes: changes, data: data}) do
    for {field, value} <- changes,
        not match?(%Ecto.Changeset{}, value),
        not is_list(value),
        into: %{} do
      {field, %{before: json_safe(Map.get(data, field)), after: json_safe(value)}}
    end
  end

  @doc "`value`, or its inspected form if JSON can't hold it."
  def json_safe(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def json_safe(%module{} = value) when module in [DateTime, NaiveDateTime, Date],
    do: value

  def json_safe(value) when is_atom(value), do: Atom.to_string(value)
  def json_safe(value), do: inspect(value)

  @doc """
  A page of log entries, newest first, with their actors. Filters (string
  keys, as in the page's query string): `"action"` and `"actor"` (a user id).
  """
  def list(filters, page) do
    StaffAction
    |> filter_by(:action, filters["action"])
    |> filter_by(:actor_id, filters["actor"])
    |> order_by(desc: :id)
    |> preload(:actor)
    |> Repo.paginate(page: page, page_size: 50)
  end

  defp filter_by(query, _field, blank) when blank in [nil, ""], do: query
  defp filter_by(query, field, value), do: where(query, [a], field(a, ^field) == ^value)

  @doc "The users who have log entries (for the actor filter), by username."
  def actors do
    User
    |> where([u], u.id in subquery(select(StaffAction, [a], a.actor_id)))
    |> order_by(:username)
    |> Repo.all()
  end

  @doc """
  The target types `targets/1` looks up. Others (e.g. roles edited in the
  Kaffy admin) have no page of their own.
  """
  def linked_types, do: ~w(thread post category user)

  @doc """
  The entries' targets that still exist, as a map from `{type, id}` to the
  record. Posts come with their thread, to link to them.
  """
  def targets(entries) do
    ids = Enum.group_by(entries, & &1.target_type, & &1.target_id)

    [
      {"thread", Thread, []},
      {"post", Post, [:thread]},
      {"category", Category, []},
      {"user", User, []}
    ]
    |> Enum.flat_map(fn {type, schema, preloads} ->
      schema
      |> where([r], r.id in ^Map.get(ids, type, []))
      |> preload(^preloads)
      |> Repo.all()
      |> Enum.map(&{{type, &1.id}, &1})
    end)
    |> Map.new()
  end
end
