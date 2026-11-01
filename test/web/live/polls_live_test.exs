defmodule FirestormWeb.Web.PollsLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Forums, Polls, Repo}
  alias FirestormWeb.Forums.Poll

  setup do
    author = user_fixture(%{username: "pollster"})
    voter = user_fixture(%{username: "voter"})
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "Colors", body: "first post"})
    %{author: author, voter: voter, category: category, thread: thread}
  end

  defp path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  defp poll_post(thread, user, attrs) do
    attrs = Map.merge(%{"options_text" => "Red\nGreen"}, attrs)
    {:ok, post} = Forums.create_post(thread, user, %{body: "vote!", poll: Polls.attrs(attrs, 0)})
    {post, Poll |> Repo.get_by!(post_id: post.id) |> Repo.preload(:options)}
  end

  test "add a poll to a reply", %{conn: conn, author: author, thread: thread} do
    conn
    |> log_in_as(author)
    |> visit(path(thread) <> "/posts/new")
    |> click_button("Add poll")
    |> fill_in("Body", with: "Which one?")
    |> fill_in("Options (one per line, 2 to 20)", with: "Only")
    |> click_button("Reply")
    |> assert_has("#poll-composer", text: "needs at least 2 options")
    |> fill_in("Options (one per line, 2 to 20)", with: "Tea\nCoffee\nWater")
    |> select("Type", option: "Multiple choice")
    |> fill_in("At most (multiple)", with: "2")
    |> select("Show results", option: "After voting")
    |> check("Show who voted (public poll)")
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created")
    |> assert_has(".poll", text: "Multiple choice poll")
    |> assert_has(".poll", text: "pick 1 to 2")

    assert %Poll{kind: "multiple", max_choices: 2, results: "voted", public: true} =
             Repo.one(Poll)
  end

  test "start a thread with a poll", %{conn: conn, author: author, category: category} do
    conn
    |> log_in_as(author)
    |> visit(~p"/categories/#{category}/threads/new")
    |> fill_in("Title", with: "Lunch")
    |> fill_in("Body", with: "Where to?")
    |> click_button("Add poll")
    |> fill_in("Options (one per line, 2 to 20)", with: "Pizza\nSushi")
    |> select("Type", option: "Ranked choice")
    |> click_button("Create Thread")
    |> assert_has("#flash-info", text: "Thread created")
    |> assert_has(".poll", text: "Ranked choice poll")
  end

  test "vote, change it, and see results update live", %{
    conn: conn,
    author: author,
    voter: voter,
    thread: thread
  } do
    {_post, poll} = poll_post(thread, author, %{"public" => "true"})

    watcher =
      conn
      |> log_in_as(author)
      |> visit(path(thread))
      |> assert_has("#poll-#{poll.id} .poll-voters", text: "0 voters")

    conn
    |> log_in_as(voter)
    |> visit(path(thread))
    |> choose("Red")
    |> click_button("Vote")
    |> assert_has("#flash-info", text: "Vote saved")
    |> assert_has("#poll-#{poll.id} .poll-voters", text: "1 voter")
    |> choose("Green")
    |> click_button("Change vote")
    |> assert_has("#poll-option-#{Enum.at(poll.options, 1).id} .poll-option-voters",
      text: "@voter"
    )

    watcher
    |> assert_has("#poll-#{poll.id} .poll-voters", text: "1 voter")
    |> assert_has("#poll-option-#{Enum.at(poll.options, 1).id} .poll-count", text: "1 (100%)")
  end

  test "the author closes and reopens; others can't", %{
    conn: conn,
    author: author,
    voter: voter,
    thread: thread
  } do
    {_post, poll} = poll_post(thread, author, %{"results" => "closed"})

    conn
    |> log_in_as(voter)
    |> visit(path(thread))
    |> assert_has(".poll-results-hidden", text: "when the poll closes")
    |> refute_has("button", text: "Close poll")

    conn
    |> log_in_as(author)
    |> visit(path(thread))
    |> click_button("Close poll")
    |> assert_has("#flash-info", text: "Poll closed")
    |> assert_has("#poll-#{poll.id} .poll-closed")
    |> assert_has("#poll-#{poll.id} .poll-results")
    |> refute_has("#poll-#{poll.id}-vote")
    |> click_button("Reopen poll")
    |> assert_has("#flash-info", text: "Poll reopened")
    |> assert_has("#poll-#{poll.id}-vote")
  end

  test "visitors see the poll but no vote form", %{conn: conn, author: author, thread: thread} do
    {_post, poll} = poll_post(thread, author, %{})

    conn
    |> visit(path(thread))
    |> assert_has("#poll-#{poll.id}")
    |> refute_has("#poll-#{poll.id}-vote")
  end
end
