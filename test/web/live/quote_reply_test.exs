defmodule FirestormWeb.Web.QuoteReplyTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    alice = user_fixture(%{username: "alice"})

    thread =
      thread_fixture(category_fixture(), alice, %{title: "Quotable", body: "Let it crash."})

    {:ok, reply} = Forums.create_post(thread, alice, %{body: "Supervisors restart children."})
    path = ~p"/categories/#{thread.category_id}/threads/#{thread}"
    %{thread: thread, reply: reply, path: path}
  end

  setup %{conn: conn}, do: %{conn: log_in_as(conn, user_fixture())}

  test "Quote opens the reply page with an attributed quote", ctx do
    %{conn: conn, reply: reply, path: path} = ctx

    conn
    |> visit(path)
    |> click_link("a[aria-label='Quote post #{reply.id}']", "")
    |> assert_has("textarea", text: "> [@alice said:](#{path}#post-#{reply.id})")
    |> assert_has("textarea", text: "> Supervisors restart children.")
    |> assert_has("#post-preview blockquote.quote .quote-attribution a", text: "@alice said:")
    |> fill_in("Body",
      with: "> [@alice said:](#{path}#post-#{reply.id})\n>\n> Supervisors\n\nIndeed"
    )
    |> click_button("Reply")
    |> assert_has("#posts blockquote.quote .quote-attribution", text: "@alice said:")
  end

  test "a selection not in the post quotes the whole post", ctx do
    %{conn: conn, reply: reply, path: path} = ctx

    conn
    |> visit(path <> "/posts/new?" <> URI.encode_query(quote: reply.id, selection: "I love PHP"))
    |> assert_has("textarea", text: "> Supervisors restart children.")
    |> refute_has("textarea", text: "PHP")

    conn
    |> visit(path <> "/posts/new?" <> URI.encode_query(quote: reply.id, selection: "restart"))
    |> assert_has("textarea", text: "> restart")
    |> refute_has("textarea", text: "Supervisors")
  end

  test "deleted posts, other threads' posts and closed threads can't be quoted", ctx do
    %{conn: conn, thread: thread, reply: reply, path: path} = ctx
    other = thread_fixture(category_fixture(), user_fixture(), %{body: "Elsewhere"})
    [other_post] = other.posts

    conn
    |> visit(path <> "/posts/new?quote=#{other_post.id}")
    |> refute_has("textarea", text: "Elsewhere")

    {:ok, _} = Forums.delete_post(reply, admin_fixture())

    conn
    |> visit(path)
    |> refute_has("a[aria-label='Quote post #{reply.id}']")
    |> visit(path <> "/posts/new?quote=#{reply.id}")
    |> refute_has("textarea", text: "Supervisors")

    {:ok, _} = Forums.close_thread(thread, true, admin_fixture())
    conn |> visit(path) |> refute_has(".quote-link")
  end
end
