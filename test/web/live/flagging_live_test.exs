defmodule FirestormWeb.Web.FlaggingLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Flags, Forums, Repo}
  alias FirestormWeb.Forums.{Flag, Post}

  setup do
    admin = admin_fixture(%{username: "boss"})
    author = user_fixture(%{username: "author"})
    member = user_fixture(%{username: "member"})
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "Pills", body: "first post"})
    {:ok, reply} = Forums.create_post(thread, author, %{body: "buy pills"})

    %{admin: admin, author: author, member: member, thread: thread, reply: reply}
  end

  defp path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  defp hide(post) do
    for _ <- 1..3, do: {:ok, _} = Flags.flag_post(post, user_fixture(), %{"reason" => "spam"})
  end

  test "a member flags a post with a reason", %{
    conn: conn,
    member: member,
    thread: thread,
    reply: reply
  } do
    conn
    |> log_in_as(member)
    |> visit(path(thread))
    |> click_button("Flag post #{reply.id}")
    |> choose("Something else")
    |> click_button("Flag post")
    |> assert_has("#flag-form", text: "say what's wrong")
    |> fill_in("Details (required for something else)", with: "selling stuff")
    |> click_button("Flag post")
    |> assert_has("#flash-info", text: "staff will take a look")
    |> assert_has("#post-#{reply.id} .flagged", text: "Flagged")
    |> refute_has("#post-#{reply.id} .flag-count")

    assert %Flag{reason: "other", note: "selling stuff"} = Repo.get_by!(Flag, post_id: reply.id)
  end

  test "no flag button on your own posts or for visitors", ctx do
    ctx.conn
    |> log_in_as(ctx.author)
    |> visit(path(ctx.thread))
    |> refute_has(~s{button[aria-label="Flag post #{ctx.reply.id}"]})

    ctx.conn |> visit(path(ctx.thread)) |> refute_has(~s{button[aria-label^="Flag post"]})
  end

  test "flag counts are for staff only", ctx do
    {:ok, _} = Flags.flag_post(ctx.reply, ctx.member, %{"reason" => "spam"})

    ctx.conn
    |> log_in_as(ctx.admin)
    |> visit(path(ctx.thread))
    |> assert_has("#post-#{ctx.reply.id} .flag-count", text: "1")

    ctx.conn
    |> log_in_as(ctx.author)
    |> visit(path(ctx.thread))
    |> refute_has(".flag-count")
  end

  test "a hidden post: placeholder for members, content with a notice for author and admins",
       ctx do
    hide(ctx.reply)

    ctx.conn
    |> log_in_as(ctx.member)
    |> visit(path(ctx.thread))
    |> assert_has("#post-#{ctx.reply.id}.hidden-post", text: "hidden after members flagged it")
    |> refute_has("main", text: "buy pills")

    ctx.conn |> visit(path(ctx.thread)) |> refute_has("main", text: "buy pills")

    for user <- [ctx.author, ctx.admin] do
      ctx.conn
      |> log_in_as(user)
      |> visit(path(ctx.thread))
      |> assert_has(".hidden-notice", text: "pending staff review")
      |> assert_has("#post-#{ctx.reply.id}", text: "buy pills")
    end

    # Nor can members get at it another way.
    post = Repo.get!(Post, ctx.reply.id)

    ctx.conn
    |> log_in_as(ctx.member)
    |> visit(path(ctx.thread) <> "/posts/new?quote=#{post.id}")
    |> refute_has("textarea", text: "buy pills")
    |> visit(~p"/users/#{ctx.author}")
    |> refute_has("#user-posts", text: "buy pills")
  end

  test "the author is notified", %{conn: conn, author: author, reply: reply} do
    hide(reply)

    conn
    |> log_in_as(author)
    |> visit(~p"/notifications")
    |> assert_has("main", text: "was hidden after members flagged it")
  end
end
