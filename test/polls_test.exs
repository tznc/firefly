defmodule FirestormWeb.PollsTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias FirestormWeb.{AccountDeletion, AccountExport, Forums, Groups, Penalties, Polls}
  alias FirestormWeb.{TopicTimers, TopicTools}
  alias FirestormWeb.Forums.{Poll, PollVote, Post, StaffAction}

  setup do
    admin = admin_fixture()
    author = user_fixture()
    voter = user_fixture()
    category = category_fixture("Polls")
    thread = thread_fixture(category, author, %{title: "Vote here", body: "op"})
    %{admin: admin, author: author, voter: voter, category: category, thread: thread}
  end

  defp poll_post(thread, user, poll_attrs) do
    attrs = Map.merge(%{"options_text" => "Red\nGreen\nBlue"}, poll_attrs)
    {:ok, post} = Forums.create_post(thread, user, %{body: "a poll", poll: Polls.attrs(attrs, 0)})
    poll = Poll |> Repo.get_by!(post_id: post.id) |> Repo.preload(:options)
    {post, poll}
  end

  defp option_id(poll, text), do: Enum.find(poll.options, &(&1.text == text)).id

  defp counts(view, poll) do
    Map.new(poll.options, &{&1.text, Map.get(view.results.counts, &1.id, 0)})
  end

  defp log_entries(action), do: Repo.all(from(a in StaffAction, where: a.action == ^action))

  describe "creating" do
    test "with a post or a thread, from the composer", %{
      author: author,
      category: category,
      thread: thread
    } do
      {_post, poll} = poll_post(thread, author, %{"kind" => "multiple", "max_choices" => "2"})
      assert %Poll{kind: "multiple", min_choices: 1, max_choices: 2, results: "always"} = poll
      assert Enum.map(poll.options, & &1.text) == ~w(Red Green Blue)

      {:ok, new} =
        Forums.create_thread(category, author, %{
          title: "Thread poll",
          body: "pick",
          poll: Polls.attrs(%{"options_text" => "Yes\nNo", "kind" => "single"}, 0)
        })

      assert %Poll{kind: "single"} = Repo.get_by!(Poll, post_id: new.first_post.id)
    end

    test "invalid polls stop the post", %{author: author, thread: thread} do
      bad = fn attrs ->
        assert {:error, changeset} =
                 Forums.create_post(thread, author, %{body: "x", poll: Polls.attrs(attrs, 0)})

        changeset.changes.poll
      end

      assert "needs at least 2 options" in errors_on(bad.(%{"options_text" => "only one"})).options_text

      assert "has the same option twice" in errors_on(bad.(%{"options_text" => "a\nA"})).options_text

      assert errors_on(
               bad.(%{"options_text" => "a\nb", "kind" => "multiple", "max_choices" => "3"})
             ).max_choices != []

      assert errors_on(
               bad.(%{"options_text" => "a\nb", "kind" => "multiple", "min_choices" => "0"})
             ).min_choices != []

      assert "must be in the future" in errors_on(
               bad.(%{"options_text" => "a\nb", "close_at" => "2020-01-01T10:00"})
             ).close_at

      assert errors_on(bad.(%{"options_text" => "a\nb", "kind" => "plurality"})).kind != []
      assert Repo.aggregate(Poll, :count) == 0
      assert Repo.aggregate(from(p in Post, where: p.body == "x"), :count) == 0
    end

    test "the close time is local" do
      attrs = Polls.attrs(%{"close_at" => "2099-01-01T10:00"}, -60)
      assert attrs["close_at"] == ~U[2099-01-01 09:00:00Z]
      assert Polls.attrs(%{"close_at" => ""}, 0)["close_at"] == nil
    end
  end

  describe "voting" do
    test "single choice: vote and change it", %{author: author, voter: voter, thread: thread} do
      {_post, poll} = poll_post(thread, author, %{})
      {:ok, view} = Polls.vote(poll, voter, %{"option" => to_string(option_id(poll, "Red"))})
      assert view.mine == [option_id(poll, "Red")]
      {:ok, view} = Polls.vote(poll, voter, %{"option" => to_string(option_id(poll, "Blue"))})
      assert counts(view, poll) == %{"Red" => 0, "Green" => 0, "Blue" => 1}
      assert view.voters == 1

      assert {:error, :no_choice} = Polls.vote(poll, voter, %{})
      assert {:error, :no_choice} = Polls.vote(poll, voter, %{"option" => "999999"})
    end

    test "multiple choice within min and max", %{author: author, voter: voter, thread: thread} do
      {_post, poll} =
        poll_post(thread, author, %{
          "kind" => "multiple",
          "min_choices" => "2",
          "max_choices" => "2"
        })

      ids = Enum.map(poll.options, &to_string(&1.id))

      assert {:error, {:choices, 2, 2}} =
               Polls.vote(poll, voter, %{"options" => Enum.take(ids, 1)})

      assert {:error, {:choices, 2, 2}} = Polls.vote(poll, voter, %{"options" => ids})
      assert {:ok, view} = Polls.vote(poll, voter, %{"options" => Enum.take(ids, 2)})
      assert counts(view, poll) == %{"Red" => 1, "Green" => 1, "Blue" => 0}
      assert Polls.message({:choices, 2, 2}) == "Pick 2."
    end

    test "ranked choice, with instant-runoff results", %{author: author, thread: thread} do
      {_post, poll} = poll_post(thread, author, %{"kind" => "ranked"})
      [red, green, blue] = Enum.map(~w(Red Green Blue), &option_id(poll, &1))

      ballots = [
        [red, green],
        [red, green],
        [green, red],
        [blue, green],
        [blue, green]
      ]

      for ballot <- ballots do
        ranks =
          ballot
          |> Enum.with_index(1)
          |> Map.new(fn {id, rank} -> {to_string(id), to_string(rank)} end)

        {:ok, _} = Polls.vote(poll, user_fixture(), %{"ranks" => Map.put(ranks, "#{blue}x", "")})
      end

      view = Polls.view(Repo.preload(poll, :options, force: true), nil)
      # Green has fewest first choices; its ballot goes to Red, which wins 3-2.
      assert counts(view, poll) == %{"Red" => 2, "Green" => 1, "Blue" => 2}
      assert %{winners: [^red], rounds: [_, %{counts: final}]} = view.results.runoff
      assert final == %{red => 3, blue => 2}

      voter = user_fixture()

      assert {:error, :same_rank} =
               Polls.vote(poll, voter, %{"ranks" => %{"#{red}" => "1", "#{blue}" => "1"}})

      assert {:error, :no_choice} = Polls.vote(poll, voter, %{"ranks" => %{"#{red}" => ""}})
    end

    test "instant runoff edge cases" do
      assert %{winners: [], rounds: [_]} = Polls.instant_runoff([], [1, 2])
      assert %{winners: [1, 2]} = Polls.instant_runoff([[1], [2]], [1, 2])
      assert %{winners: [3]} = Polls.instant_runoff([[3], [3], [1]], [1, 2, 3])
      # Exhausted ballots drop out of the count; all the fewest go at once.
      assert %{winners: [3], rounds: [%{eliminated: [1, 2]}, _]} =
               Polls.instant_runoff([[1], [2], [3], [3]], [1, 2, 3])
    end

    test "results show as the poll says", %{author: author, voter: voter, thread: thread} do
      {_post, poll} = poll_post(thread, author, %{"results" => "voted", "public" => "true"})
      refute Polls.view(poll, voter).results?
      {:ok, view} = Polls.vote(poll, voter, %{"option" => to_string(option_id(poll, "Green"))})
      assert view.results?
      assert view.results.voters_by_option[option_id(poll, "Green")] == [voter.username]

      {_post, closed} = poll_post(thread, author, %{"results" => "closed"})
      {:ok, view} = Polls.vote(closed, voter, %{"option" => to_string(option_id(closed, "Red"))})
      refute view.results?
      assert view.results == nil
      {:ok, _} = Polls.close(closed, author)
      assert Polls.view(Repo.reload!(closed) |> Repo.preload(:options), voter).results?
    end

    test "not on unavailable posts, closed polls, or by silenced members", %{
      admin: admin,
      author: author,
      voter: voter,
      thread: thread
    } do
      {post, poll} = poll_post(thread, author, %{})
      choice = %{"option" => to_string(option_id(poll, "Red"))}

      {:ok, _} =
        Penalties.penalize(:silence, voter, admin, %{"duration" => "1d", "reason" => "shh"})

      assert {:error, {:silenced, _}} = Polls.vote(poll, voter, choice)

      other = user_fixture()
      Repo.update_all(where(Post, id: ^post.id), set: [hidden_at: DateTime.utc_now(:second)])
      assert {:error, :unavailable} = Polls.vote(poll, other, choice)

      Repo.update_all(where(Post, id: ^post.id),
        set: [hidden_at: nil, queued_at: DateTime.utc_now(:second)]
      )

      assert {:error, :unavailable} = Polls.vote(poll, other, choice)
      Repo.update_all(where(Post, id: ^post.id), set: [queued_at: nil])
      {:ok, _} = Forums.delete_post(Repo.reload!(post), author)
      assert {:error, :unavailable} = Polls.vote(poll, other, choice)
      {:ok, _} = Forums.restore_post(Repo.reload!(post), admin)

      {:ok, _} = Polls.close(poll, author)
      assert {:error, :poll_closed} = Polls.vote(poll, other, choice)
      {:ok, _} = Polls.reopen(poll, author)
      assert {:ok, _} = Polls.vote(poll, other, choice)

      {:ok, _} = Forums.archive_thread(thread, true, admin)
      assert {:error, :unavailable} = Polls.vote(poll, other, choice)
    end

    test "not in a category the voter can't read", %{admin: admin, author: author, voter: voter} do
      {:ok, team} = Groups.create_group(%{name: "team"}, admin)
      {:ok, secret} = Forums.create_category(%{title: "Secret", role_ids: [team.id]})
      thread = thread_fixture(secret, admin, %{title: "Secret poll", body: "x"})
      {_post, poll} = poll_post(thread, admin, %{})

      assert {:error, :not_found} =
               Polls.vote(poll, voter, %{"option" => to_string(hd(poll.options).id)})

      _ = author
    end
  end

  describe "closing" do
    test "by the author or staff (logged), not others", %{
      admin: admin,
      author: author,
      voter: voter,
      thread: thread
    } do
      {_post, poll} = poll_post(thread, author, %{})
      assert {:error, :unauthorized} = Polls.close(poll, voter)
      {:ok, closed} = Polls.close(poll, author)
      assert closed.closed_at
      assert log_entries("poll.close") == []

      {:ok, _} = Polls.reopen(poll, admin)
      assert [_] = log_entries("poll.open")
      {:ok, _} = Polls.close(poll, admin)
      assert [_] = log_entries("poll.close")
      # Already closed: nothing more.
      {:ok, _} = Polls.close(poll, admin)
      assert [_] = log_entries("poll.close")
    end

    test "automatically at its time, by the scheduler", %{
      author: author,
      voter: voter,
      thread: thread
    } do
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      {post, poll} =
        poll_post(thread, author, %{"close_at" => FirestormWeb.LocalTime.to_input(at, 0)})

      Forums.subscribe("forums:thread:#{thread.id}")

      assert Polls.run_due() == 0
      refute Poll.closed?(poll)
      assert Polls.run_due(DateTime.add(at, 1)) == 1
      assert Repo.reload!(poll).closed_at == Repo.reload!(poll).close_at
      post_id = post.id
      assert_received {:poll_updated, ^post_id}
      assert Polls.run_due(DateTime.add(at, 2)) == 0

      # Reopened past its time: it stays open.
      past = DateTime.add(DateTime.utc_now(:second), -60)
      Repo.update_all(where(Poll, id: ^poll.id), set: [close_at: past, closed_at: past])
      {:ok, reopened} = Polls.reopen(Repo.reload!(poll), author)
      assert reopened.close_at == nil
      refute Poll.closed?(reopened)
      assert {:ok, _} = Polls.vote(poll, voter, %{"option" => to_string(hd(poll.options).id)})

      # One that fell due while the app was down.
      {_post, later} =
        poll_post(thread, author, %{"close_at" => FirestormWeb.LocalTime.to_input(at, 0)})

      Repo.update_all(where(Poll, id: ^later.id),
        set: [close_at: DateTime.add(DateTime.utc_now(:second), -60)]
      )

      start_supervised!({TopicTimers.Scheduler, interval: 50})
      :sys.get_state(TopicTimers.Scheduler)
      assert Repo.reload!(later).closed_at
    end
  end

  test "votes announce live, and a split carries the poll along", %{
    admin: admin,
    author: author,
    voter: voter,
    category: category,
    thread: thread
  } do
    {post, poll} = poll_post(thread, author, %{})
    {:ok, _} = Polls.vote(poll, voter, %{"option" => to_string(option_id(poll, "Red"))})

    {:ok, split} =
      TopicTools.split(
        thread,
        [post.id],
        {:new, %{"title" => "Poll thread", "category_id" => category.id}},
        admin
      )

    Forums.subscribe("forums:thread:#{split.id}")

    {:ok, view} =
      Polls.vote(poll, user_fixture(), %{"option" => to_string(option_id(poll, "Red"))})

    post_id = post.id
    assert_received {:poll_updated, ^post_id}
    assert counts(view, poll)["Red"] == 2

    target = thread_fixture(category, admin, %{title: "Merged", body: "t"})
    {:ok, target} = TopicTools.merge(split, target, admin)

    assert %{poll: %{id: poll_id}} =
             Polls.views(Repo.preload(target, :posts).posts, voter)[post.id]

    assert poll_id == poll.id
  end

  test "export, and deletion keeps votes anonymously", %{
    author: author,
    voter: voter,
    thread: thread
  } do
    {post, poll} = poll_post(thread, author, %{"public" => "true", "kind" => "ranked"})
    [red, green, _] = Enum.map(poll.options, & &1.id)
    {:ok, _} = Polls.vote(poll, voter, %{"ranks" => %{"#{green}" => "1", "#{red}" => "2"}})

    assert %{votes: [%{post_id: post_id, option: 2, rank: 1}, %{option: 1, rank: 2}], created: []} =
             AccountExport.build(voter).polls

    assert post_id == post.id

    assert [%{options: ~w(Red Green Blue), kind: "ranked"}] =
             AccountExport.build(author).polls.created

    {:ok, deleted} = AccountDeletion.delete_account(voter, voter.username)
    assert Repo.aggregate(PollVote, :count) == 2
    assert Polls.view(poll, nil).results.voter_names == [deleted.username]
  end
end
