defmodule FirestormWeb.PluginUITest do
  use FirestormWeb.Web.ConnCase

  @moduletag :capture_log

  import Ecto.Query
  import FirestormWeb.DataCase, only: [errors_on: 1]
  import FirestormWeb.PluginHelpers
  import Phoenix.LiveViewTest, only: [live: 2, render_hook: 3, assert_reply: 2]

  alias FirestormWeb.{Forums, Plugins, RateLimit, Repo}
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

  describe "widget storage" do
    test "is the viewer's own, within limits", %{member: member} do
      other = user_fixture()
      store = &UI.widget_storage("hello", &1, &2, &3)

      assert {:ok, nil} = store.("set", %{"key" => "n", "value" => %{"a" => [1]}}, member)
      assert {:ok, nil} = store.("set", %{"key" => "m", "value" => 2}, member)
      assert {:ok, %{"a" => [1]}} = store.("get", %{"key" => "n"}, member)
      assert {:ok, ["m", "n"]} = store.("list", %{"prefix" => ""}, member)
      assert {:ok, nil} = store.("delete", %{"key" => "m"}, member)
      assert {:ok, ["n"]} = store.("list", %{}, member)
      assert {:ok, nil} = store.("get", %{"key" => "n"}, other)
      assert Storage.get({"hello", member.id}, "n") == %{"a" => [1]}
      assert Storage.get("hello", "n") == nil

      assert {:error, "sign in to save data"} = store.("get", %{"key" => "n"}, nil)
      assert {:error, "sign in to save data"} = store.("set", %{"key" => "n", "value" => 1}, nil)

      assert {:error, "no such plugin"} =
               UI.widget_storage("missing", "get", %{"key" => "n"}, member)

      assert {:error, "invalid storage request"} = store.("drop", %{}, member)

      assert {:error, "values must be at most 8 KB"} =
               store.("set", %{"key" => "big", "value" => String.duplicate("x", 9_000)}, member)

      Application.put_env(:firestorm_web, Storage, user_max_keys: 1)

      try do
        assert {:error, "storage quota exceeded: too many keys"} =
                 store.("set", %{"key" => "m", "value" => 1}, member)
      after
        Application.delete_env(:firestorm_web, Storage)
      end
    end

    test "writes are rate limited per plugin and member", %{member: member} do
      config = Application.get_env(:firestorm_web, RateLimit)
      Application.put_env(:firestorm_web, RateLimit, limits: [plugin_storage: {2, 60_000}])
      on_exit(fn -> Application.put_env(:firestorm_web, RateLimit, config) end)

      assert {:ok, nil} = UI.widget_storage("hello", "set", %{"key" => "a", "value" => 1}, member)
      assert {:ok, nil} = UI.widget_storage("hello", "delete", %{"key" => "a"}, member)

      assert {:error, "too many writes: slow down"} =
               UI.widget_storage("hello", "set", %{"key" => "a", "value" => 1}, member)

      # Reads aren't writes; another member has their own allowance.
      assert {:ok, nil} = UI.widget_storage("hello", "get", %{"key" => "a"}, member)

      assert {:ok, nil} =
               UI.widget_storage("hello", "set", %{"key" => "a", "value" => 1}, user_fixture())
    end

    test "a widget can't reach another member's data, whatever it sends", %{
      conn: conn,
      member: member,
      thread: thread
    } do
      other = user_fixture()
      :ok = Storage.put({"hello", other.id}, "secret", "theirs")
      path = ~p"/categories/#{thread.category_id}/threads/#{thread}"

      {:ok, view, _html} = live(log_in_as(conn, member), path)
      forged = %{"plugin" => "hello", "key" => "secret", "user_id" => other.id}

      render_hook(view, "plugin_widget_storage", Map.put(forged, "op", "get"))
      assert_reply(view, %{ok: nil})

      render_hook(
        view,
        "plugin_widget_storage",
        Map.merge(forged, %{"op" => "set", "value" => 1})
      )

      assert_reply(view, %{ok: nil})

      render_hook(view, "plugin_widget_storage", Map.put(forged, "op", "delete"))
      assert_reply(view, %{ok: nil})

      assert Storage.get({"hello", other.id}, "secret") == "theirs"
      assert Storage.list({"hello", member.id}) == []

      {:ok, anonymous, _html} = live(conn, path)
      render_hook(anonymous, "plugin_widget_storage", Map.put(forged, "op", "get"))
      assert_reply(anonymous, %{error: "sign in to save data"})
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
