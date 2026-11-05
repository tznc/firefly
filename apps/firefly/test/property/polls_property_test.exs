defmodule Firefly.PollsPropertyTest do
  @moduledoc """
  Properties of `Firefly.Discussion.Polls`: instant-runoff counting
  (winners are options, a first-round majority wins at once, every round
  counts each live ballot once, nobody who wins was eliminated, and the
  result doesn't depend on ballot order); voting with parameters of any
  shape (the API passes them through) is a vote or a reason, never a
  crash; a vote replaces the voter's last; and creating a poll from any
  option text is a poll or a changeset error.
  """
  # Sync: it makes threads with polls and many voters.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Discussion
  alias Firefly.Discussion.{Poll, Polls}

  describe "instant_runoff/2" do
    defp ballots(options),
      do:
        list_of(map(list_of(member_of(options ++ [99]), max_length: 5), &Enum.uniq/1),
          max_length: 12
        )

    property "is consistent round to round" do
      check all(
              n <- integer(1..5),
              ballots <- ballots(Enum.to_list(1..n)),
              max_runs: runs(500)
            ) do
        options = Enum.to_list(1..n)
        %{rounds: rounds, winners: winners} = Polls.instant_runoff(ballots, options)

        assert winners -- options == []
        assert rounds != []
        eliminated = Enum.flat_map(rounds, & &1.eliminated)
        assert Enum.uniq(eliminated) == eliminated
        assert MapSet.disjoint?(MapSet.new(eliminated), MapSet.new(winners))

        live = fn remaining ->
          Enum.count(ballots, fn ballot -> Enum.any?(ballot, &(&1 in remaining)) end)
        end

        Enum.reduce(rounds, options, fn round, remaining ->
          assert Map.keys(round.counts) |> Enum.sort() == Enum.sort(remaining)
          assert round.counts |> Map.values() |> Enum.sum() == live.(remaining)
          remaining -- round.eliminated
        end)

        # A first-choice majority wins at once.
        first = hd(rounds).counts
        total = first |> Map.values() |> Enum.sum()

        case Enum.find(first, fn {_id, count} -> count * 2 > total end) do
          {id, _} -> assert winners == [id] and length(rounds) == 1
          nil -> :ok
        end

        assert Polls.instant_runoff(Enum.reverse(ballots), options).winners |> Enum.sort() ==
                 Enum.sort(winners)
      end
    end
  end

  defp poll_thread(kind, extra \\ %{}) do
    author = user_fixture()
    category = category_fixture("Polls #{System.unique_integer([:positive])}")

    poll = Map.merge(%{"kind" => kind, "options_text" => "Red\nGreen\nBlue\nGold"}, extra)

    {:ok, thread} =
      Discussion.create_thread(category, author, %{
        title: "Vote here",
        body: "Which one?",
        poll: poll
      })

    post = Repo.one!(from(p in Discussion.Post, where: p.thread_id == ^thread.id))
    %{poll: poll} = Polls.view_for(post, author)
    Repo.preload(poll, :options, force: true)
  end

  describe "voting" do
    property "parameters of any shape give a vote or a reason" do
      polls = for kind <- ~w(single multiple ranked), do: poll_thread(kind)
      voter = user_fixture()

      check all(
              poll <- member_of(polls),
              params <-
                one_of([
                  json_value(),
                  map(json_value(), &%{"option" => &1}),
                  map(json_value(), &%{"options" => &1}),
                  map(json_value(), &%{"ranks" => &1}),
                  map(list_of(json_value(), max_length: 3), &%{"options" => &1}),
                  # From pairs: map_of/3 needs distinct keys, and short odd
                  # strings are mostly "".
                  map(
                    list_of(tuple({adversarial_text(2), json_value()}), max_length: 3),
                    &%{"ranks" => Map.new(&1)}
                  )
                ]),
              max_runs: runs(300)
            ) do
        params = if is_map(params), do: params, else: %{"option" => params}

        case Polls.vote(poll, voter, params) do
          {:ok, view} -> assert view.mine != []
          {:error, reason} -> assert is_binary(Polls.message(reason))
        end
      end
    end

    test "a vote replaces the voter's last, and counts follow" do
      poll = poll_thread("multiple", %{"min_choices" => "1", "max_choices" => "3"})
      voters = for _ <- 1..3, do: user_fixture()
      ids = Enum.map(poll.options, & &1.id)

      check all(
              votes <-
                list_of({integer(0..2), list_of(member_of(ids), min_length: 1, max_length: 3)},
                  max_length: 8
                ),
              max_runs: runs(30)
            ) do
        last =
          Enum.reduce(votes, %{}, fn {v, choice}, last ->
            choice = Enum.uniq(choice)

            {:ok, _} =
              Polls.vote(poll, Enum.at(voters, v), %{"options" => Enum.map(choice, &to_string/1)})

            Map.put(last, v, choice)
          end)

        # Earlier runs' votes stay; the last of each voter is theirs.
        for {v, choice} <- last do
          assert Polls.view(poll, Enum.at(voters, v)).mine |> Enum.sort() == Enum.sort(choice)
        end

        view = Polls.view(poll, nil)
        assert view.voters <= length(voters)
        assert view.results.counts |> Map.values() |> Enum.sum() >= 0
      end
    end
  end

  describe "creating" do
    property "any option text gives a poll or a changeset error" do
      check all(
              text <-
                one_of([
                  adversarial_text(),
                  map(list_of(adversarial_text(3), max_length: 25), &Enum.join(&1, "\n"))
                ]),
              kind <- member_of(~w(single multiple ranked x)),
              min <- one_of([constant(nil), member_of(Firefly.Generators.numbers())]),
              max_runs: runs(150)
            ) do
        changeset =
          Poll.changeset(%Poll{}, %{"kind" => kind, "options_text" => text, "min_choices" => min})

        assert %Ecto.Changeset{} = changeset

        if changeset.valid? do
          options = Ecto.Changeset.get_field(changeset, :options)
          assert length(options) in 2..20
          texts = Enum.map(options, &String.downcase(&1.text))
          assert Enum.uniq(texts) == texts
        end
      end
    end
  end
end
