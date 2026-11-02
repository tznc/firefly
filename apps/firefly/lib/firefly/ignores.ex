defmodule Firefly.Ignores do
  @moduledoc """
  Muting and ignoring other members (as Discourse does):

    * **mute**: no notifications from them (replies, mentions, likes,
      accepted answers, private messages), and they can't start a private
      conversation with you or add you to one
    * **ignore**: muting, plus their posts are collapsed behind an "ignored
      content" placeholder (revealed on click), and the threads they start
      and conversations they start are left out of your lists and inbox.
      An ignore may expire (see `durations/0`); a mute lasts until undone.

  Staff can't be muted or ignored (they must be able to reach everyone), nor
  can you mute yourself. Ignores are private: nobody else is told.
  """

  import Ecto.Query

  alias Firefly.{Forums, Repo}
  alias Firefly.Forums.{User, UserIgnore}

  @levels ~w(mute ignore)

  @durations [
    {"Forever", "forever"},
    {"1 day", "1d"},
    {"1 week", "1w"},
    {"1 month", "1m"},
    {"3 months", "3m"},
    {"6 months", "6m"},
    {"1 year", "1y"}
  ]

  @days %{"1d" => 1, "1w" => 7, "1m" => 30, "3m" => 91, "6m" => 182, "1y" => 365}

  @doc "The levels: `mute` and `ignore`."
  def levels, do: @levels

  @doc "How long an ignore lasts, as select options."
  def durations, do: @durations

  @doc """
  Mutes or ignores (`level`) `target` as `user`, replacing any earlier
  choice. `duration` (see `durations/0`) only applies to ignoring.
  """
  def set(%User{} = user, %User{} = target, level, duration \\ "forever")
      when level in @levels do
    cond do
      user.id == target.id ->
        {:error, :self}

      Forums.admin?(target) ->
        {:error, :staff}

      true ->
        now = NaiveDateTime.utc_now()

        Repo.insert(
          %UserIgnore{
            user_id: user.id,
            ignored_user_id: target.id,
            level: level,
            expires_at: if(level == "ignore", do: expiry(duration)),
            inserted_at: now,
            updated_at: now
          },
          on_conflict: {:replace, [:level, :expires_at, :updated_at]},
          conflict_target: [:user_id, :ignored_user_id]
        )
    end
  end

  defp expiry(duration) do
    case @days[duration] do
      nil -> nil
      days -> DateTime.add(DateTime.utc_now(:second), days, :day)
    end
  end

  @doc """
  Applies a choice from a form (see `FireflyWeb.ForumComponents.ignore_form/1`):
  `"normal"` removes any mute or ignore, else see `set/4`. Returns `{:ok,
  message}` to show, or `{:error, message}`.
  """
  def choose(%User{} = user, %User{} = target, "normal", _duration) do
    :ok = remove(user, target)
    {:ok, "@#{target.username} is no longer muted or ignored."}
  end

  def choose(%User{} = user, %User{} = target, level, duration) when level in @levels do
    case set(user, target, level, duration) do
      {:ok, _} when level == "mute" -> {:ok, "@#{target.username} is muted."}
      {:ok, _} -> {:ok, "@#{target.username} is ignored."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def choose(_user, _target, _level, _duration), do: {:error, "Pick normal, mute or ignore."}

  @doc "Stops muting or ignoring `target`."
  def remove(%User{id: user_id}, %User{id: target_id}) do
    UserIgnore
    |> where([i], i.user_id == ^user_id and i.ignored_user_id == ^target_id)
    |> Repo.delete_all()

    :ok
  end

  @doc "What to tell the user when `set/4` fails."
  def message(:self), do: "You can't mute or ignore yourself."
  def message(:staff), do: "Staff can't be muted or ignored."

  @doc "`user`'s mutes and ignores in force, with the other user, by username."
  def list(%User{id: user_id}) do
    UserIgnore
    |> active()
    |> where([i], i.user_id == ^user_id)
    |> join(:inner, [i], u in assoc(i, :ignored_user))
    |> order_by([i, u], asc: u.username)
    |> preload([i, u], ignored_user: u)
    |> Repo.all()
  end

  @doc "How `viewer` treats `target`: `\"mute\"`, `\"ignore\"` or nil."
  def level(nil, _target), do: nil

  def level(%User{id: viewer_id}, %User{id: target_id}) do
    UserIgnore
    |> active()
    |> where([i], i.user_id == ^viewer_id and i.ignored_user_id == ^target_id)
    |> select([i], i.level)
    |> Repo.one()
  end

  @doc "The ids of the users `viewer` ignores (not just mutes)."
  def ignored_ids(nil), do: []

  def ignored_ids(%User{id: viewer_id}) do
    UserIgnore
    |> active()
    |> where([i], i.user_id == ^viewer_id and i.level == "ignore")
    |> select([i], i.ignored_user_id)
    |> Repo.all()
  end

  @doc """
  Which of the users with ids `user_ids` mute or ignore the user with id
  `author_id`: a MapSet of ids. Their notifications from that user are
  skipped.
  """
  def muters(nil, _user_ids), do: MapSet.new()
  def muters(_author_id, []), do: MapSet.new()

  def muters(author_id, user_ids) do
    UserIgnore
    |> active()
    |> where([i], i.ignored_user_id == ^author_id and i.user_id in ^user_ids)
    |> select([i], i.user_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Which of the users with ids `other_ids` the user with id `user_id` mutes or ignores (a MapSet)."
  def muted_by(_user_id, []), do: MapSet.new()

  def muted_by(user_id, other_ids) do
    UserIgnore
    |> active()
    |> where([i], i.user_id == ^user_id and i.ignored_user_id in ^other_ids)
    |> select([i], i.ignored_user_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Whether `user` mutes or ignores `other`."
  def muted?(%User{id: user_id}, %User{id: other_id}),
    do: MapSet.member?(muted_by(user_id, [other_id]), other_id)

  def muted?(_user, _other), do: false

  @doc "The export of `user`'s mutes and ignores (see `Firefly.AccountExport`)."
  def export(%User{} = user) do
    for ignore <- list(user) do
      %{
        username: ignore.ignored_user.username,
        level: ignore.level,
        expires_at: ignore.expires_at
      }
    end
  end

  defp active(query) do
    now = DateTime.utc_now(:second)
    where(query, [i], is_nil(i.expires_at) or i.expires_at > ^now)
  end
end
