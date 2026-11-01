defmodule FirestormWeb.Web.LikesTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    author = user_fixture(%{username: "author"})
    thread = thread_fixture(category_fixture(), author, %{title: "Likeable"})
    [post] = FirestormWeb.Repo.preload(thread, :posts).posts
    path = ~p"/categories/#{thread.category_id}/threads/#{thread}"
    %{author: author, thread: thread, post: post, path: path}
  end

  test "members like and unlike posts; readers see it live", ctx do
    %{conn: conn, post: post, path: path} = ctx
    reader = visit(conn, path)

    conn
    |> log_in_as(user_fixture(%{username: "bob"}))
    |> visit(path)
    |> click_button("Like post #{post.id}")
    |> assert_has("#post-#{post.id}-likes .like-count", text: "1")
    |> assert_has("#post-#{post.id}-likes[data-tip='Liked by @bob']")
    |> assert_has("button[aria-pressed=true]", text: "1")

    reader
    |> assert_has("#post-#{post.id}-likes .like-count", text: "1")
    |> refute_has("#post-#{post.id}-likes button")

    conn
    |> log_in_as(Forums.get_user_by_username("bob"))
    |> visit(path)
    |> click_button("Unlike post #{post.id}")
    |> assert_has("button[aria-pressed=false]")
    |> refute_has("#post-#{post.id}-likes .like-count")
  end

  test "a like refreshes only the likes, not the whole thread", ctx do
    %{conn: conn, author: author, thread: thread, post: post, path: path} = ctx
    reader = user_fixture(%{username: "reader"})
    session = conn |> log_in_as(reader) |> visit(path)
    read_before = Forums.thread_read(reader, thread).last_read_post_id

    # A post that arrives without a live update: a full reload would show it
    # and move the reader's read position.
    FirestormWeb.Repo.insert!(%Forums.Post{
      thread_id: thread.id,
      user_id: author.id,
      body: "Quiet"
    })

    Forums.like_post(post, user_fixture(%{username: "bob"}))

    session
    |> assert_has("#post-#{post.id}-likes .like-count", text: "1")
    |> refute_has("p", text: "Quiet")

    assert Forums.thread_read(reader, thread).last_read_post_id == read_before
  end

  test "authors can't like their own posts", %{conn: conn, author: author, post: post, path: path} do
    Forums.like_post(post, user_fixture(%{username: "fan"}))

    conn
    |> log_in_as(author)
    |> visit(path)
    |> refute_has("button[aria-label='Like post #{post.id}']")
    |> assert_has("#post-#{post.id}-likes .like-count", text: "1")
  end

  test "the author's liked notification links to the post", ctx do
    %{conn: conn, author: author, post: post, path: path} = ctx
    Forums.like_post(post, user_fixture(%{username: "fan"}))

    conn
    |> log_in_as(author)
    |> visit(~p"/notifications")
    |> click_button("#notifications button", "@fan liked your post")
    |> assert_path(path)
  end
end
