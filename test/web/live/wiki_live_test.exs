defmodule FirestormWeb.Web.WikiLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Forums, Penalties, Repo, TopicTools}
  alias FirestormWeb.Forums.Post

  setup do
    admin = admin_fixture(%{username: "boss"})
    author = user_fixture(%{username: "author"})
    member = user_fixture(%{username: "member"})
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "FAQ", body: "first post"})
    {:ok, post} = Forums.create_post(thread, author, %{body: "Shared notes"})
    %{admin: admin, author: author, member: member, thread: thread, post: post}
  end

  defp path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"
  defp edit_path(thread, post), do: path(thread) <> "/posts/#{post.id}/edit"

  test "an admin makes a post a wiki, then a member edits it", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread,
    post: post
  } do
    conn
    |> log_in_as(member)
    |> visit(path(thread))
    |> refute_has("a[aria-label='Edit post #{post.id}']")

    conn
    |> log_in_as(admin)
    |> visit(path(thread))
    |> click_button("Make post #{post.id} a wiki")
    |> assert_has("#flash-info", text: "Post is now a wiki")
    |> assert_has("#post-#{post.id} .wiki-badge", text: "Wiki")

    conn
    |> log_in_as(member)
    |> visit(path(thread))
    |> assert_has("#post-#{post.id} .wiki-badge")
    |> click_link("a[aria-label='Edit post #{post.id}']", "")
    |> assert_has("h1", text: "Edit Wiki Post")
    |> fill_in("Body", with: "Shared notes, improved")
    |> click_button("Save edit")
    |> assert_has("#flash-info", text: "Post updated successfully.")
    |> assert_has("#post-#{post.id}-body", text: "improved")
    |> visit(path(thread) <> "/posts/#{post.id}/history")
    |> assert_has("#revision-1", text: "@member")

    conn
    |> log_in_as(admin)
    |> visit(path(thread))
    |> click_button("Make post #{post.id} a normal post")
    |> refute_has("#post-#{post.id} .wiki-badge")
  end

  test "wiki edits respect penalties and slow mode", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread,
    post: post
  } do
    {:ok, post} = Forums.set_wiki(post, true, admin)
    {:ok, thread} = TopicTools.set_slow_mode(thread, 3600, admin)
    {:ok, _} = Forums.create_post(thread, member, %{body: "my reply"})

    conn
    |> log_in_as(member)
    |> visit(edit_path(thread, post))
    |> fill_in("Body", with: "sneaky")
    |> click_button("Save edit")
    |> assert_has("#flash-error", text: "slow mode")

    {:ok, _} = TopicTools.set_slow_mode(thread, 0, admin)

    {:ok, _} =
      Penalties.penalize(:silence, member, admin, %{"duration" => "1d", "reason" => "shh"})

    conn
    |> log_in_as(member)
    |> visit(edit_path(thread, post))
    |> fill_in("Body", with: "sneaky")
    |> click_button("Save edit")
    |> assert_has("#flash-error", text: "silenced")

    assert Repo.reload!(post).body == "Shared notes"
  end

  test "two editors: the later save is told about the earlier one", %{
    conn: conn,
    admin: admin,
    author: author,
    member: member,
    thread: thread,
    post: post
  } do
    {:ok, post} = Forums.set_wiki(post, true, admin)

    session =
      conn
      |> log_in_as(member)
      |> visit(edit_path(thread, post))
      |> fill_in("Body", with: "member's version")

    {:ok, _} = Forums.update_post(post, author, %{body: "author's version"})

    session
    |> click_button("Save edit")
    |> assert_has("#flash-error", text: "edited by someone else")

    assert Repo.reload!(post).body == "author's version"
  end

  test "a wiki that stopped being one can't be saved", %{
    conn: conn,
    admin: admin,
    member: member,
    thread: thread,
    post: post
  } do
    {:ok, post} = Forums.set_wiki(post, true, admin)

    session =
      conn
      |> log_in_as(member)
      |> visit(edit_path(thread, post))
      |> fill_in("Body", with: "late edit")

    {:ok, _} = Forums.set_wiki(post, false, admin)

    session
    |> click_button("Save edit")
    |> assert_has("#flash-error")

    refute Repo.reload!(post).body == "late edit"
    refute Post.wiki?(Repo.reload!(post))
  end
end
