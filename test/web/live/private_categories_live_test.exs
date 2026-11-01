defmodule FirestormWeb.Web.PrivateCategoriesLiveTest do
  @moduledoc "Restricted categories on the web, the API, channels and email."
  use FirestormWeb.Web.ConnCase

  import Phoenix.ChannelTest, only: [socket: 3, subscribe_and_join: 3]
  require Phoenix.LiveViewTest

  alias FirestormWeb.{Forums, Groups, Repo, ReplyAddress}
  alias FirestormWeb.Forums.{Post, StaffAction}

  @endpoint FirestormWeb.Web.Endpoint

  setup do
    admin = admin_fixture(%{username: "boss"})
    insider = user_fixture(%{username: "insider"})
    outsider = user_fixture(%{username: "outsider", email: "out@example.com"})
    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    {:ok, _} = Groups.add_member(team, "insider", admin)

    public = category_fixture("Public")
    {:ok, secret} = Forums.create_category(%{title: "Secret", role_ids: [team.id]})

    thread =
      thread_fixture(secret, insider, %{title: "Launch plans", body: "classified words"})

    %{
      admin: admin,
      insider: insider,
      outsider: outsider,
      team: team,
      public: public,
      secret: secret,
      thread: thread
    }
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "outsiders and visitors get a 404 for every page of a restricted category", ctx do
    %{secret: secret, thread: thread} = ctx
    [post] = Repo.preload(thread, :posts).posts

    paths = [
      ~p"/categories/#{secret}",
      ~p"/categories/#{secret}/threads",
      ~p"/categories/#{secret}/threads/new",
      thread_path(thread),
      thread_path(thread) <> "/edit",
      thread_path(thread) <> "/posts/new",
      thread_path(thread) <> "/posts/#{post.id}/edit",
      thread_path(thread) <> "/posts/#{post.id}/history"
    ]

    for path <- paths do
      assert_error_sent(404, fn -> get(log_in_as(build_conn(), ctx.outsider), path) end)
    end

    # Visitors get the same 404 from the pages anyone may open (the others
    # send them to log in first).
    for path <- [Enum.at(paths, 0), Enum.at(paths, 1), Enum.at(paths, 3), Enum.at(paths, 7)] do
      assert_error_sent(404, fn -> get(build_conn(), path) end)
    end

    for path <- paths, do: assert(get(log_in_as(build_conn(), ctx.insider), path).status == 200)
  end

  test "category index and lists show the category, with a lock, to members only", ctx do
    ctx.conn
    |> log_in_as(ctx.outsider)
    |> visit(~p"/categories")
    |> refute_has("#categories", text: "Secret")
    |> visit(~p"/")
    |> refute_has("main", text: "Launch plans")
    |> visit(~p"/search?q=classified")
    |> refute_has("main", text: "Launch plans")
    |> refute_has("#search_category option", text: "Secret")

    ctx.conn
    |> log_in_as(ctx.insider)
    |> visit(~p"/categories")
    |> assert_has("#category-#{ctx.secret.id} .restricted-lock")
    |> refute_has("#category-#{ctx.public.id} .restricted-lock")
    |> visit(~p"/")
    |> assert_has("main a.badge .restricted-lock")
    |> visit(~p"/categories/#{ctx.secret}")
    |> assert_has("#category-restricted", text: "Only team can see this category.")
  end

  test "profiles only show posts the viewer can read", ctx do
    thread_fixture(ctx.public, ctx.insider, %{title: "Open", body: "open words"})

    ctx.conn
    |> visit(~p"/users/#{ctx.insider}")
    |> assert_has("#user-posts", text: "open words")
    |> refute_has("#user-posts", text: "classified words")
  end

  test "an open thread page leaves when its thread moves out of reach", ctx do
    open = thread_fixture(ctx.public, ctx.insider, %{title: "Open"})

    {:ok, view, _html} =
      ctx.conn |> log_in_as(ctx.outsider) |> Phoenix.LiveViewTest.live(thread_path(open))

    {:ok, _} = Forums.move_thread(open, ctx.secret, ctx.admin)

    flash = Phoenix.LiveViewTest.assert_redirect(view, ~p"/")
    assert flash["error"] == "This thread is no longer available."
  end

  test "an open history or edit page stops once its thread moves out of reach", ctx do
    open = thread_fixture(ctx.public, ctx.outsider, %{title: "Open", body: "first words"})
    [post] = Repo.preload(open, :posts).posts
    conn = log_in_as(ctx.conn, ctx.outsider)

    {:ok, history, _html} =
      Phoenix.LiveViewTest.live(conn, thread_path(open) <> "/posts/#{post.id}/history")

    {:ok, edit, _html} =
      Phoenix.LiveViewTest.live(conn, thread_path(open) <> "/posts/#{post.id}/edit")

    {:ok, _} = Forums.move_thread(open, ctx.secret, ctx.admin)

    # Saving from the already-open edit page is refused.
    edit
    |> Phoenix.LiveViewTest.form("#post-form", post: %{body: "edited words"})
    |> Phoenix.LiveViewTest.render_submit()

    flash = Phoenix.LiveViewTest.assert_redirect(edit, ~p"/")
    assert flash["error"] == "This thread is no longer available."
    assert Repo.get!(Post, post.id).body == "first words"

    # An edit made by someone who can still read it isn't pushed.
    {:ok, _} = Forums.update_post(post, ctx.admin, %{body: "staff edit"})
    flash = Phoenix.LiveViewTest.assert_redirect(history, ~p"/")
    assert flash["error"] == "This thread is no longer available."
  end

  describe "JSON API" do
    test "search", ctx do
      assert %{"results" => []} =
               ctx.conn |> get(~p"/api/v1/search?q=classified") |> json_response(200)

      assert %{"results" => [_]} =
               ctx.conn
               |> put_req_header("authorization", "Bearer #{ctx.insider.api_token}")
               |> get(~p"/api/v1/search?q=classified")
               |> json_response(200)
    end

    test "posting to a thread you can't read is a 404", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{ctx.outsider.api_token}")
        |> post(~p"/api/v1/posts", post: %{"body" => "let me in"}, thread_id: ctx.thread.id)

      assert json_response(conn, 404)["error"] == "Thread not found"
      refute Repo.get_by(Post, body: "let me in")
    end

    test "previews only link categories the user can read", ctx do
      html = fn conn ->
        conn |> post(~p"/api/v1/preview", post: %{"body" => "#secret"}) |> json_response(201)
      end

      refute html.(ctx.conn)["data"]["html"] =~ "/categories/#{ctx.secret.id}"

      assert ctx.conn
             |> put_req_header("authorization", "Bearer #{ctx.insider.api_token}")
             |> then(html)
             |> get_in(["data", "html"]) =~ "/categories/#{ctx.secret.id}"
    end
  end

  test "reply-by-email from someone who lost access is ignored", ctx do
    to = ReplyAddress.address(ctx.thread, ctx.outsider)

    ctx.conn
    |> post("/inbound/sendgrid?token=test-inbound-token", %{
      "to" => to,
      "from" => "out@example.com",
      "text" => "sneaky reply"
    })
    |> response(200)

    refute Repo.get_by(Post, body: "sneaky reply")
  end

  test "the anonymous JSON channels serve only public records", ctx do
    socket = socket(FirestormWeb.Web.UserSocket, nil, %{})

    assert {:error, %{reason: "not found"}} =
             subscribe_and_join(
               socket,
               FirestormWeb.Web.ThreadsChannel,
               "threads:#{ctx.thread.id}"
             )

    assert {:error, _} =
             subscribe_and_join(
               socket,
               FirestormWeb.Web.CategoriesChannel,
               "categories:#{ctx.secret.id}"
             )

    assert {:ok, _, store} =
             subscribe_and_join(socket, FirestormWeb.Web.StoreChannel, "store:fetch")

    ref =
      Phoenix.ChannelTest.push(store, "fetch", %{
        "categories" => [ctx.secret.id],
        "threads" => [ctx.thread.id]
      })

    Phoenix.ChannelTest.assert_reply(ref, :ok, %{categories: [], threads: []})
  end

  describe "admin" do
    test "groups: create one and manage its members", ctx do
      ctx.conn
      |> log_in_as(ctx.outsider)
      |> visit(~p"/staff/groups")
      |> assert_path(~p"/")

      session =
        ctx.conn
        |> log_in_as(ctx.admin)
        |> visit(~p"/staff/groups")
        |> assert_has("#group-#{ctx.team.id}", text: "Secret")
        |> fill_in("New group", with: "mods")
        |> click_button("Create group")
        |> assert_has("#flash-info", text: "Group mods created.")

      mods = Repo.get_by!(Forums.Role, name: "mods")

      session
      |> within("#add-member-#{mods.id}", &fill_in(&1, "Add a member to mods", with: "outsider"))
      |> click_button("#add-member-#{mods.id} button", "Add member")
      |> assert_has("#group-#{mods.id}-user-#{ctx.outsider.id}")
      |> click_button("#group-#{mods.id}-user-#{ctx.outsider.id} button", "")
      |> refute_has("#group-#{mods.id}-user-#{ctx.outsider.id}")

      assert Repo.get_by(StaffAction, action: "role.create", target_id: mods.id)
      assert Repo.get_by(StaffAction, action: "role.revoke", target_id: ctx.outsider.id)
    end

    test "restricting a category from its form", ctx do
      ctx.conn
      |> log_in_as(ctx.admin)
      |> visit(~p"/categories/#{ctx.public}/edit")
      |> select("Restricted to groups", option: "team")
      |> click_button("Save Category")
      |> assert_has("#category-restricted", text: "Only team")

      refute Bodyguard.permit?(
               Forums,
               :view_category,
               ctx.outsider,
               Forums.get_category!(ctx.public.id)
             )

      ctx.conn
      |> log_in_as(ctx.admin)
      |> visit(~p"/staff/log")
      |> assert_has("td.details", text: "restricted to: team")
    end
  end
end
