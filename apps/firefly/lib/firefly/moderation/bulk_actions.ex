defmodule Firefly.Moderation.BulkActions do
  @moduledoc """
  Bulk actions on the threads selected in a thread list:

    * `mark_read` - for anyone, on threads they may read
    * `close`, `open`, `pin`, `unpin` - the `:close_thread` policy (admins
      and leaders, trust level 4)
    * `move` (`params["category_id"]`) - the `:move_thread` policy
    * `add_tags`, `remove_tags` (`params["tags"]`) - the `:update_thread`
      policy, within the usual tag rules
    * `archive`, `unarchive`, `delete` - the `:moderate_thread` policy
      (admins)

  Each thread is checked on its own: threads the actor may not act on (or
  read) are skipped and counted. The rest change in one transaction, each
  logged in the staff log as the single action would be; open pages are
  told once it commits. Any failure (a tag rule, say) rolls the whole batch
  back.
  """

  import Ecto.Query

  alias Firefly.{Discussion, Repo, TrustLevels}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Tag, Thread}

  @policies %{
    "mark_read" => :view_thread,
    "close" => :close_thread,
    "open" => :close_thread,
    "pin" => :close_thread,
    "unpin" => :close_thread,
    "move" => :move_thread,
    "add_tags" => :update_thread,
    "remove_tags" => :update_thread,
    "archive" => :moderate_thread,
    "unarchive" => :moderate_thread,
    "delete" => :moderate_thread
  }

  # The trust level an action needs at the least (admins have them all),
  # so lists offer only what may work.
  @levels %{"mark_read" => 0, "move" => 3, "add_tags" => 3, "remove_tags" => 3}

  @doc "Every bulk action, in display order."
  def actions,
    do: ~w(mark_read close open pin unpin move add_tags remove_tags archive unarchive delete)

  @doc "The actions `user` may use on some threads (to offer them)."
  def actions_for(%User{} = user) do
    Enum.filter(actions(), fn action ->
      case @policies[action] do
        :moderate_thread -> Bodyguard.permit?(Discussion, :moderate_thread, user, nil)
        :close_thread -> TrustLevels.at_least?(user, 4)
        _other -> TrustLevels.at_least?(user, @levels[action])
      end
    end)
  end

  def actions_for(nil), do: []

  @doc """
  Runs `action` on the threads with ids `thread_ids` as `actor`. Returns
  `{:ok, %{done: count, skipped: count}}`, or `{:error, reason}`:
  `:unknown_action`, `:no_category`, `:no_tags`, or `{thread, changeset}`
  for a thread whose change failed (nothing changed then).
  """
  def perform(%User{} = actor, thread_ids, action, params \\ %{}) do
    with {:ok, policy} <- ok_or(Map.fetch(@policies, action), :unknown_action),
         {:ok, arg} <- argument(action, params) do
      threads = Repo.all(from(t in Thread, where: t.id in ^ids(thread_ids), preload: :tags))
      permitted = Enum.filter(threads, &permitted?(actor, policy, &1))

      result =
        Repo.transact(fn ->
          Enum.reduce_while(permitted, {:ok, []}, &step(action, &1, actor, arg, &2))
        end)

      with {:ok, announcements} <- result do
        announcements |> Enum.reverse() |> Enum.each(& &1.())
        {:ok, %{done: length(permitted), skipped: length(thread_ids) - length(permitted)}}
      end
    end
  end

  # Runs the action on one thread, collecting what to announce after commit.
  defp step(action, thread, actor, arg, {:ok, announcements}) do
    case run(action, thread, actor, arg) do
      {:ok, _thread, announce} -> {:cont, {:ok, [announce | announcements]}}
      {:error, reason} -> {:halt, {:error, {thread, reason}}}
    end
  end

  defp ok_or({:ok, value}, _reason), do: {:ok, value}
  defp ok_or(:error, reason), do: {:error, reason}

  defp ids(thread_ids) do
    Enum.flat_map(thread_ids, fn
      id when is_integer(id) ->
        [id]

      id ->
        case Integer.parse(to_string(id)) do
          {id, ""} -> [id]
          _ -> []
        end
    end)
  end

  defp argument("move", params) do
    case Repo.get(Category, params["category_id"] || 0) do
      nil -> {:error, :no_category}
      category -> {:ok, category}
    end
  rescue
    Ecto.Query.CastError -> {:error, :no_category}
  end

  defp argument(action, params) when action in ["add_tags", "remove_tags"] do
    case Tag.parse(params["tags"] || "") do
      [] -> {:error, :no_tags}
      names -> {:ok, names}
    end
  end

  defp argument(_action, _params), do: {:ok, nil}

  # Moving into a category also needs to be able to see it.
  defp permitted?(actor, policy, thread) do
    Bodyguard.permit?(Discussion, :view_thread, actor, thread) and
      (policy == :view_thread or Bodyguard.permit?(Discussion, policy, actor, thread))
  end

  defp run("mark_read", thread, actor, nil) do
    with {:ok, _} <- Discussion.mark_thread_read(actor, thread), do: {:ok, thread, fn -> :ok end}
  end

  defp run(action, thread, actor, nil) when action in ["close", "open"],
    do: Discussion.close_thread_unannounced(thread, action == "close", actor)

  defp run(action, thread, actor, nil) when action in ["pin", "unpin"],
    do: Discussion.pin_thread_unannounced(thread, action == "pin", actor)

  defp run(action, thread, actor, nil) when action in ["archive", "unarchive"],
    do: Discussion.archive_thread_unannounced(thread, action == "archive", actor)

  defp run("delete", thread, actor, nil), do: Discussion.delete_thread_unannounced(thread, actor)

  defp run("move", thread, actor, %Category{} = category) do
    if Bodyguard.permit?(Discussion, :view_category, actor, category),
      do: Discussion.move_thread_unannounced(thread, category, actor),
      else: {:error, :no_category}
  end

  defp run(action, thread, actor, names) when action in ["add_tags", "remove_tags"] do
    current = Enum.map(thread.tags, & &1.name)

    tags =
      if action == "add_tags",
        do: Enum.uniq(current ++ names),
        else: current -- names

    if tags == current,
      do: {:ok, thread, fn -> :ok end},
      else: Discussion.update_thread_unannounced(thread, %{tags: Enum.join(tags, ",")}, actor)
  end

  @doc "A message for an error from `perform/4`."
  def message(:unknown_action), do: "Pick an action."
  def message(:no_category), do: "Pick a category to move them to."
  def message(:no_tags), do: "Name the tags."

  def message({%Thread{title: title}, %Ecto.Changeset{errors: errors}}) do
    details = Enum.map_join(errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
    "Nothing changed: \"#{title}\" couldn't be updated (#{details})."
  end

  def message({%Thread{title: title}, _reason}),
    do: "Nothing changed: \"#{title}\" couldn't be updated."
end
