defmodule FirestormWeb.Web.PostEditingTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    author = user_fixture(%{username: "author"})
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "Edits", body: "The original text"})
    {:ok, reply} = Forums.create_post(thread, author, %{body: "A reply"})
    %{author: author, category: category, thread: thread, reply: reply}
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "the author edits a post with a live preview and sees its history", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx

    conn
    |> log_in_as(author)
    |> visit(thread_path(thread))
    |> refute_has("#post-#{reply.id} .edited")
    |> click_link("a[aria-label='Edit post #{reply.id}']", "")
    |> assert_has("textarea", text: "A reply")
    |> fill_in("Body", with: "A **better** answer")
    |> assert_has("#post-preview strong", text: "better")
    |> click_button("Save edit")
    |> assert_has("#flash-info", text: "Post updated successfully.")
    |> assert_has("#post-#{reply.id}-body strong", text: "better")
    |> click_link("#post-#{reply.id} .edited", "edited")
    |> assert_has("h1", text: "Edit history")
    |> assert_has("#revision-1", text: "@author")
    |> assert_has("#revision-1 del", text: "reply")
    |> assert_has("#revision-1 ins", text: "**better** answer")
  end

  test "diffs are escaped", %{conn: conn, author: author, reply: reply, thread: thread} do
    {:ok, _} = Forums.update_post(reply, author, %{body: "<script>alert(1)</script>"})

    html =
      conn
      |> get(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/#{reply.id}/history")
      |> html_response(200)

    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)"
  end

  test "other members can't edit", %{conn: conn, thread: thread, reply: reply} do
    conn
    |> log_in_as(user_fixture())
    |> visit(thread_path(thread))
    |> refute_has("a[aria-label='Edit post #{reply.id}']")
    |> visit(thread_path(thread) <> "/posts/#{reply.id}/edit")
    |> assert_path(thread_path(thread))
    |> assert_has("#flash-error", text: "You are not allowed to do that.")
  end

  test "closed threads can only be edited by admins", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx
    {:ok, _} = Forums.close_thread(thread, true, admin_fixture())

    conn
    |> log_in_as(author)
    |> visit(thread_path(thread))
    |> refute_has("a[aria-label='Edit post #{reply.id}']")

    build_conn()
    |> log_in_as(admin_fixture())
    |> visit(thread_path(thread) <> "/posts/#{reply.id}/edit")
    |> fill_in("Body", with: "Moderated")
    |> click_button("Save edit")
    |> assert_has("#post-#{reply.id}", text: "Moderated")
  end

  test "an edit refused after the thread closed shows an error", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx

    session =
      conn
      |> log_in_as(author)
      |> visit(thread_path(thread) <> "/posts/#{reply.id}/edit")

    {:ok, _} = Forums.close_thread(thread, true, admin_fixture())

    session
    |> fill_in("Body", with: "Too late")
    |> click_button("Save edit")
    |> assert_has("#flash-error", text: "You are not allowed to do that.")

    assert Forums.get_post!(reply.id).body == "A reply"
  end

  test "new accounts can't add too many links in an edit", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx

    conn
    |> log_in_as(author)
    |> visit(thread_path(thread) <> "/posts/#{reply.id}/edit")
    |> fill_in("Body", with: "https://a.example https://b.example https://c.example")
    |> click_button("Save edit")
    |> assert_has("p", text: "new accounts can include at most 2 links per post")
  end

  test "edits show up live for readers", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx
    session = visit(conn, thread_path(thread))

    {:ok, _} = Forums.update_post(reply, author, %{body: "Changed while you read"})

    session
    |> assert_has("#post-#{reply.id}", text: "Changed while you read")
    |> assert_has("#post-#{reply.id} .edited")
  end

  test "the history page updates live when the post is edited", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx
    session = visit(conn, thread_path(thread) <> "/posts/#{reply.id}/history")

    # Fetched the way the edit page fetches it (no user preloaded)
    post = Forums.get_post!(thread, reply.id)
    {:ok, _} = Forums.update_post(post, author, %{body: "Changed while you read"})

    assert_has(session, "#revision-1")
  end

  test "saving over someone else's edit warns and keeps your text", ctx do
    %{conn: conn, author: author, thread: thread, reply: reply} = ctx

    session =
      conn
      |> log_in_as(author)
      |> visit(thread_path(thread) <> "/posts/#{reply.id}/edit")

    {:ok, _} = Forums.update_post(reply, admin_fixture(), %{body: "Moderated"})

    session
    |> fill_in("Body", with: "My version")
    |> click_button("Save edit")
    |> assert_has("#flash-error", text: "edited by someone else")
    |> click_button("Save edit")
    |> assert_has("#flash-info", text: "Post updated successfully.")

    assert Forums.get_post!(thread, reply.id).body == "My version"
  end

  test "an edited first post stays first", ctx do
    %{conn: conn, author: author, thread: thread} = ctx
    [first, _reply] = FirestormWeb.Repo.preload(thread, :posts, force: true).posts
    {:ok, _} = Forums.update_post(first, author, %{body: "The original text, edited"})

    conn
    |> visit(thread_path(thread))
    |> assert_has("#posts > li:first-child #post-#{first.id}", text: "edited")
    |> assert_has("#reply-count", text: "1 reply")
  end
end
