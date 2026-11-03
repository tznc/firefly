defmodule FireflyWeb.AISemanticTest do
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Accounts, Discussion, Groups, Repo, SiteSettings}
  alias Firefly.AI.FakeProvider

  setup do
    admin = admin_fixture(%{username: "boss"})
    {:ok, alice} = Accounts.confirm_user(user_fixture(%{username: "alice"}))
    %{admin: admin, alice: alice, category: category_fixture("Pets")}
  end

  defp semantic(admin) do
    url =
      FakeProvider.start(fn conn ->
        data =
          conn.assigns.body["input"]
          |> Enum.with_index()
          |> Enum.map(fn {text, i} ->
            vector = if text =~ ~r/cat|kitten|feline/i, do: [1.0, 0.1], else: [0.1, 1.0]
            %{"index" => i, "embedding" => vector}
          end)

        FakeProvider.json(conn, 200, %{"data" => data})
      end)

    :ok = FakeProvider.enable(FakeProvider.provider_fixture(url), "embeddings", admin)
  end

  test "the search page's semantic toggle finds posts by meaning", ctx do
    semantic(ctx.admin)
    thread_fixture(ctx.category, ctx.alice, %{title: "Feline friends", body: "Whiskers"})

    ctx.conn
    |> visit(~p"/search?q=kitten")
    |> refute_has("#search-results li")
    |> visit(~p"/search?q=kitten&mode=semantic")
    |> assert_has("#search-results .result-title", text: "Feline friends")
    |> assert_has("#semantic-note")
  end

  test "no semantic toggle while it's off", ctx do
    ctx.conn |> visit(~p"/search") |> refute_has("input[name='search[mode]']")
  end

  test "topics end with related topics", ctx do
    semantic(ctx.admin)
    cats = thread_fixture(ctx.category, ctx.alice, %{title: "Feline friends", body: "Whiskers"})
    thread_fixture(ctx.category, ctx.alice, %{title: "Cat food", body: "Tuna"})

    ctx.conn
    |> visit(~p"/categories/#{ctx.category}/threads/#{cats}")
    |> assert_has("#related-topics a", text: "Cat food")
  end

  describe "the MCP server" do
    setup ctx do
      {:ok, _} = SiteSettings.update(%{"mcp_enabled" => "true"}, ctx.admin)
      :ok
    end

    # A minimal MCP client: one JSON-RPC message per POST.
    defp mcp(conn, token, message, headers \\ []) do
      conn =
        Enum.reduce(
          [
            {"content-type", "application/json"},
            {"accept", "application/json, text/event-stream"}
          ] ++
            headers,
          conn,
          fn {k, v}, conn -> put_req_header(conn, k, v) end
        )

      conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
      post(conn, "/mcp", Jason.encode!(message))
    end

    defp request(id, method, params \\ %{}),
      do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    test "a client initializes, lists tools and calls them as the token's member", ctx do
      {:ok, team} = Groups.create_role("team")
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      open = thread_fixture(ctx.category, ctx.alice, %{title: "Open", body: "Hello there"})
      thread_fixture(secret, ctx.admin, %{title: "Hidden", body: "Hello there"})
      token = ctx.alice.api_token

      init =
        mcp(
          build_conn(),
          token,
          request(1, "initialize", %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test-client", "version" => "1.0"}
          })
        )

      assert %{
               "id" => 1,
               "result" => %{
                 "protocolVersion" => "2025-06-18",
                 "serverInfo" => %{"name" => "firefly"}
               }
             } =
               json_response(init, 200)

      headers = [{"mcp-protocol-version", "2025-06-18"}]
      initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert response(mcp(build_conn(), token, initialized, headers), 202) == ""

      assert %{"result" => %{"tools" => tools}} =
               json_response(mcp(build_conn(), token, request(2, "tools/list"), headers), 200)

      assert "search" in Enum.map(tools, & &1["name"])

      search =
        request(3, "tools/call", %{"name" => "search", "arguments" => %{"query" => "hello"}})

      assert %{
               "result" => %{
                 "isError" => false,
                 "structuredContent" => %{"results" => [hit]},
                 "content" => [%{"type" => "text"}]
               }
             } =
               json_response(mcp(build_conn(), token, search, headers), 200)

      assert hit["topic_id"] == open.id
    end

    test "needs a token, the setting, and this site's origin", ctx do
      ping = request(1, "ping")

      conn = mcp(build_conn(), nil, ping)
      assert json_response(conn, 401)["error"]["code"] == -32_001
      assert get_resp_header(conn, "www-authenticate") != []

      assert json_response(mcp(build_conn(), "not-a-token", ping), 401)
      assert %{"result" => %{}} = json_response(mcp(build_conn(), ctx.alice.api_token, ping), 200)

      evil = [{"origin", "https://evil.example"}]
      assert response(mcp(build_conn(), ctx.alice.api_token, ping, evil), 403)

      old = [{"mcp-protocol-version", "1999-01-01"}]
      assert json_response(mcp(build_conn(), ctx.alice.api_token, ping, old), 400)

      assert response(get(build_conn(), "/mcp"), 405)

      {:ok, _} = SiteSettings.update(%{"mcp_enabled" => "false"}, ctx.admin)
      assert response(mcp(build_conn(), ctx.alice.api_token, ping), 404)
    end

    test "is rate limited per member", ctx do
      limits = Application.get_env(:firefly, Firefly.RateLimit)
      Application.put_env(:firefly, Firefly.RateLimit, limits: [mcp: {1, 60_000}])
      on_exit(fn -> Application.put_env(:firefly, Firefly.RateLimit, limits) end)

      user = Repo.update!(Ecto.Changeset.change(ctx.alice, api_token: Ecto.UUID.generate()))
      assert json_response(mcp(build_conn(), user.api_token, request(1, "ping")), 200)
      assert json_response(mcp(build_conn(), user.api_token, request(2, "ping")), 429)
    end
  end
end
