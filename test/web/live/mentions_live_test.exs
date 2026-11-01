defmodule FirestormWeb.Web.MentionsLiveTest do
  use FirestormWeb.Web.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    alice = user_fixture(%{username: "alice", name: "Alice Liddell"})
    user_fixture(%{username: "alfred"})
    user_fixture(%{username: "al_x"})
    thread = thread_fixture(category_fixture(), alice, %{title: "Hello", body: "Hi"})
    path = ~p"/categories/#{thread.category_id}/threads/#{thread}"
    %{conn: log_in_as(conn, user_fixture()), path: path, alice: alice}
  end

  test "the editor suggests users by username prefix", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, path <> "/posts/new")

    render_hook(view, "mention_search", %{"prefix" => "AL"})
    assert_reply(view, %{users: users})
    assert Enum.map(users, & &1.username) == ["al_x", "alice", "alfred"]
    assert %{name: "Alice Liddell"} = Enum.find(users, &(&1.username == "alice"))

    # `_` and `%` are literal characters, not LIKE wildcards
    render_hook(view, "mention_search", %{"prefix" => "a_"})
    assert_reply(view, %{users: []})

    render_hook(view, "mention_search", %{"prefix" => "bad prefix"})
    assert_reply(view, %{users: []})
  end

  test "posts show mentions as profile links", %{conn: conn, path: path, alice: alice} do
    conn
    |> visit(path <> "/posts/new")
    |> fill_in("Body", with: "Thanks @alice!")
    |> assert_has("#post-preview a[href$='/users/#{alice.id}']", text: "@alice")
    |> click_button("Reply")
    |> assert_has("#posts a[href$='/users/#{alice.id}']", text: "@alice")
  end
end
