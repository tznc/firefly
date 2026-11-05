defmodule FireflyWeb.StripNulTest do
  @moduledoc """
  NUL characters (which Postgres can't store) are stripped wherever they
  come in over the web, and a NUL the database still refuses is a clean
  error, not a crash.
  """
  use FireflyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest,
    only: [live: 2, live_isolated: 2, render_submit: 2, render_click: 2, element: 2]

  alias Firefly.{Repo, Text}
  alias Firefly.Discussion.{Category, Post, Thread}
  alias Firefly.Notifications.ReplyAddress

  setup do
    member = user_fixture()
    category = category_fixture()
    %{member: member, category: category, thread: thread_fixture(category, member)}
  end

  describe "the endpoint" do
    defp parse(conn) do
      conn
      |> Plug.Parsers.call(
        Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)
      )
      |> FireflyWeb.Plugs.StripNul.call([])
    end

    test "strips NUL from nested form and query params" do
      conn =
        Plug.Test.conn(:post, "/x%00y/z?q=a%00b&f[]=%00", "post[body]=b%00&post[tags][]=t%00")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> parse()

      assert conn.path_info == ["xy", "z"]
      assert conn.query_params == %{"q" => "ab", "f" => [""]}
      assert conn.body_params == %{"post" => %{"body" => "b", "tags" => ["t"]}}
      assert conn.params["post"] == %{"body" => "b", "tags" => ["t"]}
      assert conn.params["q"] == "ab"
    end

    test "strips NUL (and \\u0000) from nested JSON" do
      conn =
        Plug.Test.conn(:post, "/x", ~s({"a":{"b":["c\\u0000d"]},"k\\u0000":"\\u0000"}))
        |> put_req_header("content-type", "application/json")
        |> parse()

      assert conn.body_params == %{"a" => %{"b" => ["cd"]}, "k" => ""}
      assert conn.params == conn.body_params
    end

    test "a thread created through the JSON API is stored without NUL", ctx do
      body =
        Jason.encode!(%{
          category_id: ctx.category.id,
          title: "Nul\u0000 in API",
          body: "a\u0000b"
        })

      response =
        ctx.conn
        |> authed(ctx.member)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/threads", body)
        |> json_response(201)

      thread = Repo.get!(Thread, response["data"]["id"])
      assert thread.title == "Nul in API"
      assert Repo.get_by!(Post, thread_id: thread.id).body == "ab"
    end

    test "a NUL in a page's path doesn't crash it", %{conn: conn, category: category} do
      assert conn |> get("/categories/#{category.id}%00") |> html_response(200) =~
               category.title
    end

    test "a reply by email is posted without NUL", ctx do
      ctx.conn
      |> post("/inbound/sendgrid?token=test-inbound-token", %{
        "to" => ReplyAddress.address(ctx.thread, ctx.member),
        "from" => ctx.member.email,
        "text" => <<"by ", 0, "email">>
      })
      |> response(200)

      assert Repo.get_by(Post, thread_id: ctx.thread.id, body: "by email")
    end
  end

  test "a LiveView event's params are stripped", ctx do
    {:ok, view, _html} =
      ctx.conn
      |> log_in_as(ctx.member)
      |> live(~p"/categories/#{ctx.category}/threads/new")

    view
    |> element("#thread-form")
    |> render_submit(%{"thread" => %{"title" => <<"Live ", 0, "title">>, "body" => <<"x", 0>>}})

    thread = Repo.get_by!(Thread, title: "Live title")
    assert Repo.get_by!(Post, thread_id: thread.id).body == "x"
  end

  describe "the database's backstop" do
    defmodule RawInsertLive do
      use FireflyWeb, :live_view

      @impl true
      def mount(_params, _session, socket), do: {:ok, socket}

      @impl true
      def render(assigns) do
        ~H"""
        <p id="flash">{Phoenix.Flash.get(@flash, :error)}</p>
        <button id="raw" phx-click="raw">Raw</button>
        """
      end

      # Text Postgres can't store (bytes that aren't UTF-8) gets as far as it.
      @impl true
      def handle_event("raw", _params, socket) do
        Repo.insert!(%Category{title: <<"raw", 0xFF>>})
        {:noreply, socket}
      end
    end

    test "a LiveView event Postgres refuses flashes an error", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, RawInsertLive)
      html = view |> element("#raw") |> render_click(%{})
      assert html =~ "contains characters that can&#39;t be saved"
      refute Repo.get_by(Category, title: "raw")
    end

    test "a request Postgres refuses is a 400 with a translated message" do
      error =
        assert_raise Postgrex.Error, fn -> Repo.insert!(%Category{title: <<"raw", 0xFF>>}) end

      assert Text.unstorable?(error)
      assert Plug.Exception.status(error) == 400

      assert FireflyWeb.ErrorHTML.render("400.html", %{reason: error}) =~
               "contains characters that can't be saved"

      assert %{errors: %{detail: "Some of that text" <> _}} =
               FireflyWeb.ErrorJSON.render("400.json", %{reason: error})

      Gettext.with_locale(FireflyWeb.Gettext, "fr", fn ->
        refute FireflyWeb.ErrorHTML.render("400.html", %{reason: error}) =~ "can't be saved"
      end)

      assert FireflyWeb.ErrorHTML.render("400.html", %{reason: %RuntimeError{}}) == "Bad Request"
    end
  end
end
