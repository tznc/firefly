defmodule FirestormWeb.Polls do
  @moduledoc """
  Polls: one per post, created with it from the composer's "Add poll" form
  (see `FirestormWeb.Forums.Poll` for the kinds and options) and stored in
  tables, not parsed from the post's markdown. They can't be edited after.

  Members vote, and change their vote, while the poll is open: a vote
  replaces the voter's previous one. Only on a post anyone may read where
  the voter may read the thread (the `:vote_poll` policy: not on a
  deleted, hidden or queued post, nor in an archived thread), and not
  while silenced (see `FirestormWeb.Posting`). Results update live on the
  thread's page (`{:poll_updated, post_id}` on its topic).

  The post's author and staff close and reopen it (the `:manage_poll`
  policy; staff on someone else's poll go to the staff log). A poll with a
  `close_at` closes then, run by `FirestormWeb.TopicTimers.Scheduler`
  (`run_due/1`), including when the time passed while the app was down.

  A poll moves with its post (merge, split). Votes are in the voter's
  account export; when an account is deleted they stay, cast by its
  anonymous placeholder (see `FirestormWeb.AccountDeletion`), so results
  don't change after the fact.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, LocalTime, Posting, Repo, StaffLog}
  alias FirestormWeb.Forums.{Poll, PollOption, PollVote, Post, Thread, User}

  @doc """
  The composer form's `params` as poll attrs for `Forums.create_post/3` or
  `create_thread/3`, with `close_at` read in the browser's `offset` (see
  `FirestormWeb.LocalTime`).
  """
  def attrs(params, offset) do
    close_at =
      case LocalTime.parse(params["close_at"], offset) do
        {:ok, at} -> at
        :blank -> nil
        :error -> params["close_at"]
      end

    params
    |> Map.take(~w(kind options_text min_choices max_choices results public))
    |> Map.put("close_at", close_at)
  end

  @doc "A changeset for the composer form."
  def change(attrs \\ %{}), do: Poll.changeset(%Poll{}, attrs)

  @doc """
  What thread pages show of the polls on `posts`, for `user` (nil: a
  visitor): a map from post id to `view/2`'s map.
  """
  def views(posts, user) do
    ids = Enum.map(posts, & &1.id)

    Poll
    |> where([p], p.post_id in ^ids)
    |> preload(:options)
    |> Repo.all()
    |> Map.new(&{&1.post_id, view(&1, user)})
  end

  @doc "The view of `post`'s poll, or nil."
  def view_for(%Post{id: post_id}, user) do
    case Poll |> preload(:options) |> Repo.get_by(post_id: post_id) do
      nil -> nil
      poll -> view(poll, user)
    end
  end

  @doc """
  A poll as `user` sees it: `poll` (options loaded), `closed?`, `mine` (the
  user's choices, option ids in rank order), `voters` (how many), and, if
  the poll's `results` setting lets them see it yet (`results?`),
  `results`: `counts` (option id to votes; first choices for ranked),
  `voters_by_option` (option id to usernames, for public polls) and, for
  ranked polls, `runoff` (see `instant_runoff/2`).
  """
  def view(%Poll{} = poll, user) do
    mine = if user, do: choices(poll, user), else: []
    closed? = Poll.closed?(poll)

    results? =
      poll.results == "always" or closed? or (poll.results == "voted" and mine != [])

    %{
      poll: poll,
      closed?: closed?,
      mine: mine,
      voters: voter_count(poll),
      results?: results?,
      results: if(results?, do: results(poll))
    }
  end

  defp choices(poll, user) do
    PollVote
    |> where([v], v.poll_id == ^poll.id and v.user_id == ^user.id)
    |> order_by([v], asc_nulls_last: v.rank, asc: v.option_id)
    |> select([v], v.option_id)
    |> Repo.all()
  end

  defp voter_count(poll) do
    PollVote
    |> where([v], v.poll_id == ^poll.id)
    |> select([v], count(v.user_id, :distinct))
    |> Repo.one()
  end

  defp results(%Poll{kind: "ranked"} = poll) do
    ballots =
      PollVote
      |> where([v], v.poll_id == ^poll.id)
      |> order_by([v], asc: v.user_id, asc: v.rank)
      |> select([v], {v.user_id, v.option_id})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.values()

    runoff = instant_runoff(ballots, Enum.map(poll.options, & &1.id))

    %{
      counts: hd(runoff.rounds).counts,
      voters_by_option: %{},
      voter_names: if(poll.public, do: voter_names(poll), else: []),
      runoff: runoff
    }
  end

  defp results(poll) do
    counts =
      PollVote
      |> where([v], v.poll_id == ^poll.id)
      |> group_by([v], v.option_id)
      |> select([v], {v.option_id, count(v.id)})
      |> Repo.all()
      |> Map.new()

    by_option =
      if poll.public do
        PollVote
        |> where([v], v.poll_id == ^poll.id)
        |> join(:inner, [v], u in assoc(v, :user))
        |> order_by([v], asc: v.id)
        |> select([v, u], {v.option_id, u.username})
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      else
        %{}
      end

    %{counts: counts, voters_by_option: by_option, voter_names: [], runoff: nil}
  end

  defp voter_names(poll) do
    PollVote
    |> where([v], v.poll_id == ^poll.id)
    |> join(:inner, [v], u in assoc(v, :user))
    |> distinct([v, u], u.username)
    |> order_by([v, u], asc: u.username)
    |> select([v, u], u.username)
    |> Repo.all()
  end

  @doc """
  Instant-runoff results for `ballots` (each a list of option ids, most
  preferred first) over `option_ids`. Each round counts every ballot for
  its most preferred option still in the running; an option with more than
  half of those wins, otherwise the options with the fewest are
  eliminated. If all remaining options tie, they all win. Returns `rounds`
  (each with `counts` and the options it `eliminated`) and `winners`.
  """
  def instant_runoff(ballots, option_ids), do: runoff(ballots, option_ids, [])

  defp runoff(ballots, remaining, rounds) do
    first_choices =
      Enum.flat_map(ballots, fn ballot ->
        case Enum.find(ballot, &(&1 in remaining)) do
          nil -> []
          id -> [id]
        end
      end)

    counts = Map.merge(Map.new(remaining, &{&1, 0}), Enum.frequencies(first_choices))
    active = length(first_choices)
    {top, top_count} = Enum.max_by(counts, &elem(&1, 1), fn -> {nil, 0} end)
    lowest = counts |> Map.values() |> Enum.min(fn -> 0 end)
    losers = for {id, count} <- counts, count == lowest, do: id

    cond do
      active == 0 ->
        %{rounds: Enum.reverse([%{counts: counts, eliminated: []} | rounds]), winners: []}

      top_count * 2 > active ->
        %{rounds: Enum.reverse([%{counts: counts, eliminated: []} | rounds]), winners: [top]}

      length(losers) == length(remaining) ->
        %{rounds: Enum.reverse([%{counts: counts, eliminated: []} | rounds]), winners: remaining}

      true ->
        round = %{counts: counts, eliminated: losers}
        runoff(ballots, remaining -- losers, [round | rounds])
    end
  end

  @doc """
  Votes in `poll` as `user`, replacing their previous vote. `params` (the
  page's vote form): `"option"` (single choice: an option id), `"options"`
  (multiple: a list of ids) or `"ranks"` (ranked: option id to rank; blank
  ranks leave the option out). Returns `{:ok, view}` or `{:error, reason}`
  (see `message/1`).
  """
  def vote(%Poll{} = poll, %User{} = user, params) do
    result =
      Repo.transact(fn ->
        # Locked, so a vote and a close can't cross.
        poll = Poll |> lock("FOR UPDATE") |> preload(:options) |> Repo.get!(poll.id)
        post = Repo.get!(Post, poll.post_id)

        with :ok <- may_vote(poll, post, user),
             {:ok, ids} <- parse_choice(poll, params) do
          replace_votes(poll, user, ids)
          {:ok, {poll, post}}
        end
      end)

    with {:ok, {poll, post}} <- result do
      changed(post)
      {:ok, view(poll, user)}
    end
  end

  defp replace_votes(poll, user, ids) do
    Repo.delete_all(where(PollVote, poll_id: ^poll.id, user_id: ^user.id))
    now = NaiveDateTime.utc_now()
    ranked? = poll.kind == "ranked"

    rows =
      for {id, rank} <- Enum.with_index(ids, 1) do
        %{
          poll_id: poll.id,
          option_id: id,
          user_id: user.id,
          rank: if(ranked?, do: rank),
          inserted_at: now
        }
      end

    Repo.insert_all(PollVote, rows)
  end

  defp may_vote(poll, post, user) do
    thread = Repo.get!(Thread, post.thread_id)

    cond do
      not Bodyguard.permit?(Forums, :view_thread, user, thread) ->
        {:error, :not_found}

      not Bodyguard.permit?(Forums, :vote_poll, user, %{post: post, thread: thread}) ->
        {:error, :unavailable}

      Poll.closed?(poll) ->
        {:error, :poll_closed}

      true ->
        Posting.check(user, :like)
    end
  end

  defp parse_choice(%Poll{kind: "single"} = poll, %{"option" => id}), do: option_ids(poll, [id])

  defp parse_choice(%Poll{kind: "multiple"} = poll, %{"options" => ids}) when is_list(ids) do
    with {:ok, ids} <- option_ids(poll, ids) do
      if length(ids) in poll.min_choices..poll.max_choices//1,
        do: {:ok, ids},
        else: {:error, {:choices, poll.min_choices, poll.max_choices}}
    end
  end

  defp parse_choice(%Poll{kind: "ranked"} = poll, %{"ranks" => ranks}) when is_map(ranks) do
    ranked =
      for {id, rank} <- ranks, {rank, ""} <- [Integer.parse(to_string(rank))], do: {id, rank}

    cond do
      ranked == [] ->
        {:error, :no_choice}

      length(Enum.uniq_by(ranked, &elem(&1, 1))) != length(ranked) ->
        {:error, :same_rank}

      true ->
        ranked
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.map(&elem(&1, 0))
        |> then(&option_ids(poll, &1))
    end
  end

  defp parse_choice(_poll, _params), do: {:error, :no_choice}

  # The ids as the poll's option ids, in order; an error for any other.
  defp option_ids(poll, ids) do
    valid = MapSet.new(poll.options, & &1.id)

    parsed =
      for id <- ids, {id, ""} <- [Integer.parse(to_string(id))], MapSet.member?(valid, id), do: id

    cond do
      parsed == [] -> {:error, :no_choice}
      length(parsed) != length(ids) or Enum.uniq(parsed) != parsed -> {:error, :no_choice}
      true -> {:ok, parsed}
    end
  end

  @doc "Closes `poll` as `actor` (its post's author or staff)."
  def close(%Poll{} = poll, %User{} = actor), do: set_closed(poll, actor, true)

  @doc "Reopens `poll` as `actor`; a `close_at` that has passed is dropped."
  def reopen(%Poll{} = poll, %User{} = actor), do: set_closed(poll, actor, false)

  defp set_closed(poll, actor, close?) do
    result =
      Repo.transact(fn ->
        poll = Poll |> lock("FOR UPDATE") |> Repo.get!(poll.id)
        post = Repo.get!(Post, poll.post_id)
        thread = Repo.get!(Thread, post.thread_id)

        cond do
          not manageable?(actor, post, thread) -> {:error, :unauthorized}
          # Already so: nothing to do (or log).
          Poll.closed?(poll) == close? -> {:ok, {poll, post}}
          true -> {:ok, {update_closed(poll, close?, actor, post, thread), post}}
        end
      end)

    with {:ok, {updated, post}} <- result do
      changed(post)
      {:ok, updated}
    end
  end

  defp update_closed(poll, close?, actor, post, thread) do
    updated = poll |> Ecto.Changeset.change(closed_changes(poll, close?)) |> Repo.update!()
    log(actor, if(close?, do: "poll.close", else: "poll.open"), post, thread)
    updated
  end

  defp manageable?(actor, post, thread),
    do: Bodyguard.permit?(Forums, :manage_poll, actor, %{post: post, thread: thread})

  defp closed_changes(_poll, true), do: [closed_at: DateTime.utc_now(:second)]

  # Reopened past its closing time: it stays open until closed by hand.
  defp closed_changes(poll, false) do
    if Poll.closed?(%{poll | closed_at: nil}),
      do: [closed_at: nil, close_at: nil],
      else: [closed_at: nil]
  end

  # Staff on someone else's poll.
  defp log(actor, action, post, thread) do
    if post.user_id != actor.id,
      do: StaffLog.record(actor, action, post, %{thread: thread.title, post_id: post.id})
  end

  # Open thread pages refresh the poll. The post is read now: a merge or
  # split may have moved it since.
  defp changed(%Post{id: id}) do
    thread_id = Repo.one(from(p in Post, where: p.id == ^id, select: p.thread_id))

    Phoenix.PubSub.broadcast(
      FirestormWeb.PubSub,
      "forums:thread:#{thread_id}",
      {:poll_updated, id}
    )
  end

  @doc """
  Closes every poll whose `close_at` has come by `now`, one transaction
  each. Returns how many it closed.
  """
  def run_due(now \\ DateTime.utc_now()), do: run_due(now, 0)

  defp run_due(now, count) do
    result =
      Repo.transact(fn ->
        Poll
        |> where([p], is_nil(p.closed_at) and p.close_at <= ^now)
        |> order_by([p], asc: p.close_at, asc: p.id)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()
        |> case do
          nil -> {:ok, nil}
          poll -> {:ok, poll |> Ecto.Changeset.change(closed_at: poll.close_at) |> Repo.update!()}
        end
      end)

    case result do
      {:ok, nil} ->
        count

      {:ok, poll} ->
        changed(%Post{id: poll.post_id})
        run_due(now, count + 1)
    end
  end

  @doc """
  The user's poll data, for the account export: their votes (which option
  of which post's poll, by position, with its rank) and the polls they
  created.
  """
  def export(%User{} = user) do
    votes =
      PollVote
      |> where([v], v.user_id == ^user.id)
      |> join(:inner, [v], o in PollOption, on: o.id == v.option_id)
      |> join(:inner, [v], p in Poll, on: p.id == v.poll_id)
      |> order_by([v], asc: v.poll_id, asc_nulls_last: v.rank, asc: v.id)
      |> select([v, o, p], %{
        post_id: p.post_id,
        option: o.position,
        rank: v.rank,
        voted_at: v.inserted_at
      })
      |> Repo.all()

    created =
      Poll
      |> join(:inner, [p], post in Post, on: post.id == p.post_id and post.user_id == ^user.id)
      |> order_by([p], asc: p.id)
      |> preload(:options)
      |> Repo.all()
      |> Enum.map(fn poll ->
        poll
        |> Map.take([
          :post_id,
          :kind,
          :min_choices,
          :max_choices,
          :results,
          :public,
          :close_at,
          :closed_at
        ])
        |> Map.put(:options, Enum.map(poll.options, & &1.text))
      end)

    %{votes: votes, created: created}
  end

  def message(:not_found), do: Posting.message(:not_found)
  def message(:unavailable), do: "This poll can't be voted on."
  def message(:poll_closed), do: "This poll is closed."
  def message(:no_choice), do: "Pick an option."
  def message(:same_rank), do: "Give each option a different rank."
  def message({:choices, min, min}), do: "Pick #{min}."
  def message({:choices, min, max}), do: "Pick between #{min} and #{max}."
  def message(:unauthorized), do: "You can't manage this poll."
  def message(reason), do: Posting.message(reason)
end
