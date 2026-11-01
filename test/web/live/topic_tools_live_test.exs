defmodule FirestormWeb.Web.TopicToolsLiveTest do
  use FirestormWeb.Web.ConnCase

  require Phoenix.LiveViewTest

  import Ecto.Query, only: [where: 2]

  alias FirestormWeb.{Forums, Repo, TopicTimers, TopicTools}
  alias FirestormWeb.Forums.{Post, Thread}

  setup do
    admin = admin_fixture()
    member = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, member, %{title: "Original", body: "opening"})
    {:ok, reply} = Forums.create_post(thread, member, %{body: "a tangent"})
    %{admin: admin, member: member, category: category, thread: thread, reply: reply}
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"
  defp tools_path(thread), do: thread_path(thread) <> "/tools"

  test "only admins get the tools", %{conn: conn, admin: admin, member: member, thread: thread} do
    conn
    |> log_in_as(member)
    |> visit(tools_path(thread))
    |> assert_path("/")
    |> assert_has("#flash-error")

    build_conn()
    |> log_in_as(admin)
    |> visit(thread_path(thread))
    |> click_link("#moderation a", "Merge, split, timer")
    |> assert_path(tools_path(thread))
  end

  test "merging leaves a stub that redirects", %{
    conn: conn,
    admin: admin,
    member: member,
    category: category,
    thread: thread
  } do
    target = thread_fixture(category, member, %{title: "Target", body: "main"})

    conn
    |> log_in_as(admin)
    |> visit(tools_path(thread))
    |> fill_in("Thread URL or id", with: "https://firefly.example" <> thread_path(target))
    |> click_button("Merge")
    |> assert_path(thread_path(target))
    |> assert_has("#flash-info", text: "Thread merged into Target.")
    |> assert_has("#posts", text: "a tangent")

    build_conn()
    |> log_in_as(member)
    |> visit(thread_path(thread))
    |> assert_path(thread_path(target))

    build_conn()
    |> log_in_as(member)
    |> visit(thread_path(thread) <> "/posts/new")
    |> assert_path(thread_path(target) <> "/posts/new")

    build_conn() |> visit(~p"/categories/#{category}") |> refute_has("#thread-#{thread.id}")
  end

  test "merging into an unknown thread says so", %{conn: conn, admin: admin, thread: thread} do
    conn
    |> log_in_as(admin)
    |> visit(tools_path(thread))
    |> fill_in("Thread URL or id", with: "nonsense")
    |> click_button("Merge")
    |> assert_has("#flash-error", text: "No such thread.")
  end

  test "splitting replies into a new thread", %{
    conn: conn,
    admin: admin,
    thread: thread,
    reply: reply
  } do
    other = category_fixture("Off topic")

    session =
      conn
      |> log_in_as(admin)
      |> visit(tools_path(thread))
      |> check("#split-post-#{reply.id}", "a tangent", exact: false)
      |> fill_in("New thread title", with: "The tangent")
      |> select("New thread category", option: "Off topic")
      |> click_button("Move posts")

    new = Repo.get_by!(Thread, title: "The tangent")
    assert new.category_id == other.id

    session
    |> assert_path(thread_path(new))
    |> assert_has("#posts", text: "a tangent")

    assert Repo.get!(Post, reply.id).thread_id == new.id
  end

  test "splitting needs a reply", %{conn: conn, admin: admin, thread: thread} do
    conn
    |> log_in_as(admin)
    |> visit(tools_path(thread))
    |> fill_in("New thread title", with: "Nothing")
    |> click_button("Move posts")
    |> assert_has("#flash-error", text: "Select at least one reply.")
  end

  test "a timer shows on the thread and can be cancelled", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread
  } do
    session =
      conn
      |> log_in_as(admin)
      |> visit(tools_path(thread))
      |> select("Action", option: "Close")
      |> fill_in("In", with: "2")
      |> select("Unit", option: "hours")
      |> click_button("Set timer")
      |> assert_has("#flash-info", text: "Timer set.")
      |> assert_has("#current-timer", text: "Closes")

    timer = TopicTimers.get_timer(thread)
    assert DateTime.diff(timer.run_at, DateTime.utc_now()) in 7100..7200

    build_conn()
    |> log_in_as(member)
    |> visit(thread_path(thread))
    |> assert_has("#thread-timer", text: "Closes")

    session
    |> click_button("Cancel timer")
    |> assert_has("#flash-info", text: "Timer cancelled.")
    |> refute_has("#current-timer")

    build_conn() |> visit(thread_path(thread)) |> refute_has("#thread-timer")
  end

  test "slow mode holds members back, everywhere", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread
  } do
    conn
    |> log_in_as(admin)
    |> visit(tools_path(thread))
    |> select("Interval", option: "One reply every 1 hour")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "Slow mode is on.")

    # The member just replied (in setup).
    build_conn()
    |> log_in_as(member)
    |> visit(thread_path(thread))
    |> assert_has("#slow-mode-notice", text: "one reply every 1 hour per member")
    |> assert_has("#slow-mode-notice", text: "You can reply again in 1 hour")
    |> visit(thread_path(thread) <> "/posts/new")
    |> fill_in("Body", with: "again")
    |> click_button("Reply")
    |> assert_has("#flash-error", text: "This thread is in slow mode: you can reply again in")

    api =
      build_conn()
      |> put_req_header("authorization", "Bearer #{member.api_token}")
      |> post(~p"/api/v1/posts", post: %{body: "again"}, thread_id: thread.id)

    assert json_response(api, 429)["error"] =~ "slow mode"

    # An hour later it's fine.
    Repo.update_all(where(Post, user_id: ^member.id),
      set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -3601)]
    )

    build_conn()
    |> log_in_as(member)
    |> visit(thread_path(thread) <> "/posts/new")
    |> fill_in("Body", with: "again")
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created")
  end

  test "an open page of a merged thread follows it", %{
    conn: conn,
    admin: admin,
    member: member,
    category: category,
    thread: thread
  } do
    target = thread_fixture(category, member, %{title: "Target", body: "main"})

    {:ok, view, _html} =
      conn |> log_in_as(member) |> Phoenix.LiveViewTest.live(thread_path(thread))

    {:ok, _} = TopicTools.merge(thread, target, admin)

    {path, flash} = Phoenix.LiveViewTest.assert_redirect(view)
    assert path == thread_path(target)
    assert flash["info"] =~ "merged into another one"
  end
end
