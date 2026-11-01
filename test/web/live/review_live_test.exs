defmodule FirestormWeb.Web.ReviewLiveTest do
  use FirestormWeb.Web.ConnCase

  require Phoenix.LiveViewTest

  alias FirestormWeb.{Flags, Forums, Repo}
  alias FirestormWeb.Forums.{Post, SiteSetting, StaffAction}

  setup do
    admin = admin_fixture(%{username: "boss"})
    author = user_fixture(%{username: "author"})
    category = category_fixture()
    thread = thread_fixture(category, author, %{title: "Pills", body: "first"})
    {:ok, reply} = Forums.create_post(thread, author, %{body: "buy pills"})
    %{admin: admin, author: author, category: category, thread: thread, reply: reply}
  end

  defp flag(post, reason \\ "spam") do
    {:ok, _} = Flags.flag_post(post, user_fixture(), %{"reason" => reason})
  end

  test "only admins can open the queue", %{conn: conn, author: author} do
    conn
    |> log_in_as(author)
    |> visit(~p"/staff/review")
    |> assert_path(~p"/")
    |> refute_has("nav a", text: "Review")
  end

  test "flagged posts: grouped with their flags, decided, logged", ctx do
    flag(ctx.reply)
    flag(ctx.reply, "off_topic")

    ctx.conn
    |> log_in_as(ctx.admin)
    |> visit(~p"/staff/review")
    |> assert_has("#review-count", text: "1")
    |> assert_has("#flagged-#{ctx.reply.id}", text: "buy pills")
    |> assert_has("#flagged-#{ctx.reply.id} .flag", count: 2)
    |> assert_has("#flagged-#{ctx.reply.id} .flag", text: "Off-topic")
    |> click_button("#flagged-#{ctx.reply.id} button", "Agree and hide")
    |> assert_has("#flash-info", text: "the post stays hidden")
    |> assert_has("#review-empty")
    |> refute_has("#review-count")

    assert Repo.get!(Post, ctx.reply.id).hidden_at
    assert Repo.get_by(StaffAction, action: "flag.agree", target_id: ctx.reply.id)
  end

  test "agree and silence uses the silence flow", ctx do
    flag(ctx.reply)

    ctx.conn
    |> log_in_as(ctx.admin)
    |> visit(~p"/staff/review")
    |> within("#silence-#{ctx.reply.id}", fn session ->
      session
      |> select("Silence for", option: "1 day")
      |> fill_in("Reason (the author sees it)", with: "Spam, again")
      |> click_button("Agree and silence author")
    end)
    |> assert_has("#flash-info", text: "the author is silenced")

    assert %{silence_reason: "Spam, again"} = Forums.get_user!(ctx.author.id)
  end

  test "disagree and restore shows the post again", ctx do
    for _ <- 1..3, do: flag(ctx.reply)
    assert Repo.get!(Post, ctx.reply.id).hidden_at

    ctx.conn
    |> log_in_as(ctx.admin)
    |> visit(~p"/staff/review")
    |> assert_has("#flagged-#{ctx.reply.id} .badge", text: "hidden")
    |> click_button("#flagged-#{ctx.reply.id} button", "Disagree and restore")
    |> assert_has("#flash-info", text: "shown again")

    refute Repo.get!(Post, ctx.reply.id).hidden_at
  end

  test "the queue and badge update live for other staff", ctx do
    {:ok, view, _html} =
      ctx.conn |> log_in_as(ctx.admin) |> Phoenix.LiveViewTest.live(~p"/staff/review")

    assert Phoenix.LiveViewTest.has_element?(view, "#review-empty")

    flag(ctx.reply)
    assert Phoenix.LiveViewTest.has_element?(view, "#flagged-#{ctx.reply.id}")
    assert Phoenix.LiveViewTest.has_element?(view, "#review-count", "1")

    other = admin_fixture()
    {:ok, _} = FirestormWeb.Review.defer(Repo.get!(Post, ctx.reply.id), other)
    refute Phoenix.LiveViewTest.has_element?(view, "#flagged-#{ctx.reply.id}")
    refute Phoenix.LiveViewTest.has_element?(view, "#review-count")
  end

  describe "approval for new users" do
    setup do
      Repo.insert!(%SiteSetting{key: "approve_new_user_posts", value: "1"})
      :ok
    end

    test "a new user's thread awaits approval, then staff approve it", ctx do
      newbie = user_fixture(%{username: "newbie"})
      member = user_fixture(%{username: "member"})

      ctx.conn
      |> log_in_as(newbie)
      |> visit(~p"/categories/#{ctx.category}/threads/new")
      |> fill_in("Title", with: "Hello all")
      |> fill_in("Body", with: "my first post")
      |> click_button("Create Thread")
      |> assert_has("#flash-info", text: "awaiting approval")
      |> assert_has(".awaiting-approval", text: "Awaiting approval")

      thread = Repo.get_by!(Forums.Thread, title: "Hello all")
      path = ~p"/categories/#{ctx.category}/threads/#{thread}"

      assert_error_sent(404, fn -> get(log_in_as(build_conn(), member), path) end)
      ctx.conn |> log_in_as(member) |> visit(~p"/") |> refute_has("main", text: "Hello all")

      ctx.conn
      |> log_in_as(ctx.admin)
      |> visit(~p"/staff/review")
      |> assert_has("#queued", text: "New thread")
      |> click_button("Approve")
      |> assert_has("#flash-info", text: "Approved and published.")

      ctx.conn |> log_in_as(member) |> visit(path) |> assert_has("main", text: "my first post")
    end

    test "staff reject a reply with a reason, and the author is told", ctx do
      newbie = user_fixture(%{username: "newbie"})
      {:ok, reply} = Forums.create_post(ctx.thread, newbie, %{body: "queued reply"})

      ctx.conn
      |> log_in_as(ctx.author)
      |> visit(~p"/categories/#{ctx.category}/threads/#{ctx.thread}")
      |> refute_has("main", text: "queued reply")

      ctx.conn
      |> log_in_as(ctx.admin)
      |> visit(~p"/staff/review")
      |> within("#reject-#{reply.id}", fn session ->
        session
        |> fill_in("Reason for rejecting post #{reply.id}", with: "Please stay on topic")
        |> click_button("Reject")
      end)
      |> assert_has("#flash-info", text: "Rejected")

      ctx.conn
      |> log_in_as(newbie)
      |> visit(~p"/notifications")
      |> assert_has("main", text: "Staff didn't approve your reply")
    end
  end
end
