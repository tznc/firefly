defmodule FireflyWeb.IgnoreLiveTest do
  use FireflyWeb.ConnCase

  alias Firefly.Accounts.Ignores

  setup do
    %{me: user_fixture(%{username: "me"}), troll: user_fixture(%{username: "troll"})}
  end

  test "ignoring from a profile collapses their posts, which can be revealed", %{
    conn: conn,
    me: me,
    troll: troll
  } do
    category = category_fixture()
    thread = thread_fixture(category, me, %{title: "Mine"})
    {:ok, post} = Firefly.Discussion.create_post(thread, troll, %{body: "Something rude"})

    conn = log_in_as(conn, me)

    conn
    |> visit(~p"/users/#{troll}")
    |> select("How you see @troll", option: "Ignored: also hide their posts")
    |> select("Ignore for", option: "1 week")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "@troll is ignored.")
    |> assert_has("#ignore summary", text: "Ignored")

    assert Ignores.level(me, troll) == "ignore"

    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}")
    |> assert_has("#post-#{post.id}.ignored-post", text: "Ignored content")
    |> refute_has("#posts", text: "Something rude")
    |> click_button("Show ignored post #{post.id}")
    |> assert_has("#post-#{post.id}", text: "Something rude")
  end

  test "staff can't be ignored and you can't ignore yourself", %{conn: conn, me: me} do
    admin = admin_fixture(%{username: "boss"})
    conn = log_in_as(conn, me)

    conn |> visit(~p"/users/#{admin}") |> refute_has("#ignore-form")
    conn |> visit(~p"/users/#{me}") |> refute_has("#ignore-form")
  end

  test "managing mutes and ignores in settings", %{conn: conn, me: me, troll: troll} do
    conn
    |> log_in_as(me)
    |> visit(~p"/settings/users")
    |> assert_has("#ignores", text: "You don't mute or ignore anyone.")
    |> fill_in("Username", with: "@troll")
    |> select("Level", option: "Mute")
    |> click_button("Add")
    |> assert_has("#flash-info", text: "@troll is muted.")
    |> assert_has("#ignore-#{troll.id}", text: "Muted")
    |> fill_in("Username", with: "nobody")
    |> click_button("Add")
    |> assert_has("#flash-error", text: "No such user: @nobody")
    |> click_button("Stop muting or ignoring @troll")
    |> assert_has("#flash-info", text: "@troll is no longer muted or ignored.")
    |> refute_has("#ignore-#{troll.id}")
  end
end
