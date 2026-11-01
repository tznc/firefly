defmodule FirestormWeb.Web.ModerationTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Thread

  setup do
    admin = admin_fixture()
    member = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, member, %{title: "Moderate me"})
    %{admin: admin, member: member, category: category, thread: thread}
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "members can't moderate", %{conn: conn, member: member, thread: thread} do
    conn |> log_in_as(member) |> visit(thread_path(thread)) |> refute_has("#moderation")
  end

  test "pinning lists the thread first in its category", %{
    conn: conn,
    admin: admin,
    member: member,
    category: category,
    thread: thread
  } do
    newer = thread_fixture(category, member, %{title: "Newer"})

    assert [%{id: first} | _] = Forums.recent_threads(category)
    assert first == newer.id

    conn
    |> log_in_as(admin)
    |> visit(thread_path(thread))
    |> click_button("#moderation button", "Pin")
    |> assert_has("#flash-info", text: "Thread pinned.")
    |> assert_has("h1 .pinned")

    assert hd(Forums.recent_threads(category)).id == thread.id

    conn
    |> visit(~p"/categories/#{category}")
    |> assert_has("#thread-#{thread.id} .pinned")
  end

  test "closing stops replies everywhere", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread
  } do
    conn
    |> log_in_as(admin)
    |> visit(thread_path(thread))
    |> click_button("#moderation button", "Close")
    |> assert_has("#closed-notice", text: "closed to new replies")
    |> refute_has("a", text: "Reply")

    assert {:error, :closed} = Forums.create_post(thread, member, %{body: "too late"})

    {:ok, member} = Forums.confirm_user(member)

    build_conn()
    |> log_in_as(member)
    |> visit(thread_path(thread) <> "/posts/new")
    |> fill_in("Body", with: "too late")
    |> click_button("Reply")
    |> assert_has("#flash-error", text: "This thread is closed to new replies.")

    api =
      build_conn()
      |> put_req_header("authorization", "Bearer #{member.api_token}")
      |> post(~p"/api/v1/posts", post: %{body: "too late"}, thread_id: thread.id)

    assert json_response(api, 403)["error"] =~ "closed"

    conn
    |> log_in_as(admin)
    |> visit(thread_path(thread))
    |> click_button("#moderation button", "Reopen")
    |> refute_has("#closed-notice")

    assert {:ok, _} = Forums.create_post(Forums.get_thread!(thread.id), member, %{body: "ok"})
  end

  test "archiving makes a thread read-only and hides it from Latest", %{
    conn: conn,
    admin: admin,
    category: category,
    thread: thread
  } do
    conn
    |> log_in_as(admin)
    |> visit(thread_path(thread))
    |> click_button("#moderation button", "Archive")
    |> assert_has("#closed-notice", text: "archived")

    refute Enum.any?(Forums.latest_threads(nil), &(&1.id == thread.id))
    refute Enum.any?(Forums.top_threads("all", nil), &(&1.id == thread.id))
    # Still listed (and marked) in its category
    conn |> visit(~p"/categories/#{category}") |> assert_has("#thread-#{thread.id} .archived")
    assert Thread.closed?(Forums.get_thread!(thread.id))
  end

  test "moving a thread to another category", %{conn: conn, admin: admin, thread: thread} do
    other = category_fixture("Erlang")

    conn
    |> log_in_as(admin)
    |> visit(thread_path(thread))
    |> select("Move to category", option: "Erlang")
    |> click_button("Move")
    |> assert_has("#flash-info", text: "Thread moved to Erlang.")
    |> assert_path(~p"/categories/#{other}/threads/#{thread}")

    assert Forums.get_thread!(thread.id).category_id == other.id
  end

  test "links from before a move redirect to the thread's new place", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread
  } do
    old_path = thread_path(thread)
    other = category_fixture("Erlang")
    {:ok, moved} = Forums.move_thread(thread, other, admin)

    conn
    |> log_in_as(member)
    |> visit(old_path)
    |> assert_path(thread_path(moved))
    |> assert_has("h1", text: "Moderate me")
  end

  test "bad moderation input is reported, not a crash", %{
    conn: conn,
    admin: admin,
    thread: thread
  } do
    require Phoenix.LiveViewTest
    {:ok, view, _} = conn |> log_in_as(admin) |> Phoenix.LiveViewTest.live(thread_path(thread))

    assert Phoenix.LiveViewTest.render_click(view, "moderate", %{"action" => "explode"}) =~
             "update the thread"

    assert Phoenix.LiveViewTest.render_submit(view, "move", %{"move" => %{"category_id" => "0"}}) =~
             "no longer exists"
  end

  test "archived threads are read-only to their author", %{
    member: member,
    admin: admin,
    thread: thread
  } do
    {:ok, archived} = Forums.archive_thread(thread, true, admin)
    refute FirestormWeb.Web.Authorization.can?(member, :update_thread, archived)
    refute FirestormWeb.Web.Authorization.can?(member, :delete_thread, archived)
    assert FirestormWeb.Web.Authorization.can?(admin, :update_thread, archived)
  end

  test "a thread closed while the reply form is open gets a flash, not a crash", %{
    conn: conn,
    member: member,
    thread: thread
  } do
    {:ok, member} = Forums.confirm_user(member)
    session = conn |> log_in_as(member) |> visit(thread_path(thread) <> "/posts/new")

    # Closed after the form opened (the reply form holds a stale thread)
    Forums.Thread
    |> FirestormWeb.Repo.get!(thread.id)
    |> Ecto.Changeset.change(closed_at: DateTime.utc_now(:second))
    |> FirestormWeb.Repo.update!()

    session
    |> fill_in("Body", with: "too late")
    |> click_button("Reply")
    |> assert_has("#flash-error", text: "closed to new replies")
  end
end
