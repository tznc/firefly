defmodule FirestormWeb.PluginUITest do
  use FirestormWeb.Web.ConnCase

  @moduletag :capture_log

  import Ecto.Query
  import FirestormWeb.DataCase, only: [errors_on: 1]
  import FirestormWeb.PluginHelpers

  alias FirestormWeb.{Forums, Plugins, Repo}
  alias FirestormWeb.Forums.{Post, StaffAction}
  alias FirestormWeb.Plugins.{Events, Fields, Jobs, Storage, UI}

  setup do
    admin = admin_fixture(%{username: "boss"})
    member = user_fixture(%{username: "mia"})
    id = install_example!(admin, "hello")

    thread =
      thread_fixture(category_fixture("Public"), member, %{
        title: "Hi",
        body: ~s([hello name="World"])
      })

    %{admin: admin, member: member, thread: thread, id: id}
  end

  describe "the example plugin" do
    test "uses the content, event, job, moderation and field hooks", %{
      admin: admin,
      member: member,
      thread: thread
    } do
      [post] = Repo.preload(thread, :posts).posts
      html = FirestormWeb.Markdown.render(post.body, nil, post: post, thread: thread)
      assert html =~ ~s(<span class="hello">Hello, World!</span>)
      assert html =~ "This post says hello."

      assert Events.deliver_due() == 1
      assert Storage.get("hello", "thread_created") == 1
      assert Fields.get("hello", "post", post.id) == %{"hellos" => 1}

      Jobs.run_due(DateTime.utc_now())
      Jobs.run_due(DateTime.add(DateTime.utc_now(), 3601))
      assert Storage.get("hello", "last_tally")

      {:ok, _} =
        Plugins.update_settings(
          "hello",
          %{"greeting" => "Hello", "blocked_words" => "darn"},
          admin
        )

      assert {:error, changeset} = Forums.create_post(thread, member, %{body: "darn it"})
      assert errors_on(changeset).body == [~s(Please don't say "darn".)]
    end
  end

  describe "assets" do
    test "are served with a strict, sandboxing CSP", %{conn: conn} do
      conn = get(conn, "/plugins/hello/assets/widget.html")
      assert html_response(conn, 200) =~ "Firefly.ready"
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "connect-src 'none'"
      assert csp =~ "sandbox allow-scripts"
      refute csp =~ "allow-same-origin"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "only listed assets of active plugins", %{conn: conn, admin: admin} do
      assert conn |> get("/plugins/hello/assets/index.js") |> response(404)
      assert conn |> get("/plugins/hello/assets/plugin.json") |> response(404)
      assert conn |> get("/plugins/hello/assets/../plugin.json") |> response(404)
      {:ok, _} = Plugins.disable("hello", admin)
      assert conn |> get("/plugins/hello/assets/widget.html") |> response(404)
    end

    test "the widget SDK", %{conn: conn} do
      assert conn |> get("/plugins/sdk.js") |> response(200) =~ "window.Firefly"
    end
  end

  describe "widgets" do
    test "show in sandboxed frames under public posts", %{
      conn: conn,
      thread: thread,
      admin: admin
    } do
      session = visit(conn, ~p"/categories/#{thread.category_id}/threads/#{thread}")

      session
      |> assert_has(
        "[phx-hook='PluginWidget'][data-plugin='hello'] iframe[sandbox='allow-scripts'][src='/plugins/hello/assets/widget.html']"
      )

      {:ok, role} = Forums.create_role("staff")
      {:ok, private} = Forums.create_category(%{title: "Staff", role_ids: [role.id]})
      secret = thread_fixture(private, admin)

      conn
      |> log_in_as(admin)
      |> visit(~p"/categories/#{private.id}/threads/#{secret}")
      |> refute_has("[phx-hook='PluginWidget']")
    end

    test "calls reach the plugin's handler; failures don't leak details", %{member: member} do
      assert {:ok, %{"views" => 1, "greeting" => "Hello, mia!"}} =
               UI.call_widget(
                 "hello",
                 "view",
                 nil,
                 %{"post_id" => 1},
                 member,
                 "user:#{member.id}"
               )

      assert {:error, "the plugin failed"} =
               UI.call_widget("hello", "nope", nil, %{}, nil, "ip:1")

      assert {:error, "no such plugin"} = UI.call_widget("missing", "view", nil, %{}, nil, "ip:1")
    end
  end

  describe "pages" do
    test "render sanitized HTML in the layout, or a frame app", %{conn: conn, member: member} do
      conn
      |> log_in_as(member)
      |> visit("/plugins/hello")
      |> assert_has("h1", text: "Hello")
      |> assert_has(".plugin-view", text: "Hello, mia!")
      |> visit("/plugins/hello/app")
      |> assert_has("h1", text: "Hello app")
      |> assert_has("iframe[sandbox='allow-scripts'][src='/plugins/hello/assets/app.html']")
    end

    test "an unknown plugin's page is not found", %{conn: conn} do
      conn
      |> visit("/plugins/nothing/here")
      |> assert_path("/")
      |> assert_has("#flash-error", text: "Page not found.")
    end

    test "the plugin's staff section and endpoint secret", %{conn: conn, admin: admin} do
      secret = Plugins.secret("hello")

      conn
      |> log_in_as(admin)
      |> visit("/staff/plugins/hello")
      |> assert_has("#plugin-admin h2", text: "Hello's numbers")
      |> assert_has("#plugin-secret", text: secret)
      |> click_button("New secret")
      |> refute_has("#plugin-secret", text: secret)

      assert Plugins.secret("hello") != secret
      assert [_] = Repo.all(from(a in StaffAction, where: a.action == "plugin.secret"))
    end
  end

  describe "endpoints" do
    test "authenticate with the plugin's secret or a member's token", %{
      conn: conn,
      member: member
    } do
      assert %{"error" => "authentication required"} =
               conn |> get("/api/plugins/hello/stats") |> json_response(401)

      assert %{"error" => "authentication required"} =
               conn
               |> put_req_header("x-plugin-secret", "wrong")
               |> get("/api/plugins/hello/stats")
               |> json_response(401)

      assert %{"views" => 0, "user" => nil} =
               conn
               |> put_req_header("x-plugin-secret", Plugins.secret("hello"))
               |> get("/api/plugins/hello/stats")
               |> json_response(200)

      assert %{"user" => "mia"} =
               conn
               |> put_req_header("authorization", "Bearer #{member.api_token}")
               |> get("/api/plugins/hello/stats")
               |> json_response(200)

      assert %{"error" => "no such endpoint"} =
               conn
               |> put_req_header("x-plugin-secret", Plugins.secret("hello"))
               |> post("/api/plugins/hello/other", %{"x" => 1})
               |> json_response(404)

      assert conn |> get("/api/plugins/missing/stats") |> json_response(404)
    end
  end

  test "a hidden post's widget isn't shown", %{conn: conn, thread: thread, member: member} do
    {:ok, reply} = Forums.create_post(thread, member, %{body: "reply"})
    Repo.update!(Ecto.Changeset.change(reply, hidden_at: DateTime.utc_now(:second)))

    conn
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}")
    |> refute_has("#plugin-hello-post_footer-#{reply.id}")
    |> assert_has("[id^='plugin-hello-post_footer-']")

    assert %Post{} = Repo.get!(Post, reply.id)
  end
end
