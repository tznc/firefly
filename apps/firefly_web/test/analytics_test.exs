defmodule FireflyWeb.AnalyticsTest do
  # The analytics buffer is shared by every test.
  use FireflyWeb.ConnCase, async: false

  import Ecto.Query

  import Phoenix.LiveViewTest,
    only: [live: 2, has_element?: 2]

  alias Firefly.{Analytics, Repo, SiteSettings}
  alias Firefly.Analytics.Buffer
  alias Firefly.Discussion.Thread

  @browser "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"

  setup do
    Buffer.take()
    thread = thread_fixture(category_fixture(), user_fixture())
    {:ok, thread: thread, path: ~p"/categories/#{thread.category_id}/threads/#{thread}"}
  end

  defp views(kind) do
    Analytics.flush()
    today = Date.utc_today()

    Enum.find_value(Analytics.page_views(today, today), 0, fn
      {_date, ^kind, count} -> count
      _ -> nil
    end)
  end

  defp browser(conn, headers \\ []) do
    Enum.reduce([{"user-agent", @browser} | headers], conn, fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
  end

  test "page views count by kind, with the referring domain", %{conn: conn} do
    # A LiveView page counts when it connects.
    {:ok, _view, _html} =
      live(browser(conn, [{"referer", "https://news.example/item"}]), ~p"/categories")

    {:ok, _view, _html} = live(conn |> browser() |> log_in_as(user_fixture()), ~p"/categories")

    # Crawlers don't connect: they count on the request.
    conn
    |> put_req_header("user-agent", "Mozilla/5.0 (compatible; bingbot/2.0)")
    |> put_req_header("referer", "https://spam.example/")
    |> get(~p"/categories")

    conn |> put_req_header("accept", "application/json") |> get(~p"/api/v1/search?q=otp")

    assert views("anonymous") == 1
    assert views("crawler") == 1
    assert views("logged_in") == 1
    assert views("api") == 1
    today = Date.utc_today()
    assert Analytics.top_referrers(today, today) == [{"news.example", 1}]
  end

  test "opening a thread counts a view, once a day per viewer", %{conn: conn} = ctx do
    conn = browser(conn)
    {:ok, _view, _html} = live(conn, ctx.path)
    {:ok, _view, _html} = live(conn, ctx.path)
    Analytics.flush()

    assert Repo.get!(Thread, ctx.thread.id).views == 1
    viewers = Repo.all(from(v in "analytics_topic_viewers", select: v.viewer))
    assert [<<"a:", _hash::binary>>] = viewers

    user = user_fixture()
    {:ok, _view, html} = live(log_in_as(conn, user), ctx.path)
    Analytics.flush()

    assert Repo.get!(Thread, ctx.thread.id).views == 2
    assert html =~ "1 view"
  end

  test "Do Not Track and Global Privacy Control requests only count in the totals",
       %{conn: conn} = ctx do
    for header <- [{"dnt", "1"}, {"sec-gpc", "1"}] do
      conn = browser(conn, [header, {"referer", "https://news.example/"}])
      {:ok, view, _html} = live(conn, ctx.path)
      refute has_element?(view, "#posts [data-post-id]")
    end

    assert views("anonymous") == 2
    assert Repo.get!(Thread, ctx.thread.id).views == 0
    today = Date.utc_today()
    assert Analytics.top_referrers(today, today) == []

    post_id = hd(Repo.preload(ctx.thread, :posts).posts).id

    conn
    |> put_req_header("dnt", "1")
    |> post(~p"/analytics/click", %{post_id: post_id, url: "https://elixir-lang.org/"})

    Analytics.flush()
    assert Analytics.link_clicks([%{id: post_id}]) == %{}
  end

  test "link clicks are counted from beacons and shown by the links", %{conn: conn} do
    thread =
      thread_fixture(category_fixture("Links"), user_fixture(), %{
        body: "Read https://elixir-lang.org/ now"
      })

    post_id = hd(Repo.preload(thread, :posts).posts).id

    for _ <- 1..2 do
      assert conn
             |> post(~p"/analytics/click", %{post_id: post_id, url: "https://elixir-lang.org/"})
             |> response(204)
    end

    assert conn |> post(~p"/analytics/click", %{post_id: "nope", url: "x"}) |> response(204)
    Analytics.flush()

    {:ok, view, _html} =
      live(
        browser(conn),
        ~p"/categories/#{thread.category_id}/threads/#{thread}"
      )

    assert has_element?(
             view,
             ~s|#post-#{post_id}-body[data-post-id="#{post_id}"][data-clicks='{"https://elixir-lang.org/":2}']|
           )
  end

  test "nothing is counted with the setting off", %{conn: conn} = ctx do
    {:ok, _} = SiteSettings.update(%{"analytics" => "false"}, admin_fixture())

    conn = browser(conn)
    get(conn, ~p"/categories")
    {:ok, view, _html} = live(conn, ctx.path)
    refute has_element?(view, "[data-post-id]")

    assert views("anonymous") == 0
    assert Repo.get!(Thread, ctx.thread.id).views == 0
  end

  test "pages that aren't LiveViews count on the request", %{conn: conn} do
    conn |> browser() |> get(~p"/confirm/nope")
    assert views("anonymous") == 1
  end
end
