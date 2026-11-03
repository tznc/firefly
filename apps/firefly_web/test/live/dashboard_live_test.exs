defmodule FireflyWeb.DashboardLiveTest do
  use FireflyWeb.ConnCase, async: true

  setup do
    admin = admin_fixture()
    thread_fixture(category_fixture(), user_fixture(), %{title: "Counted"})
    {:ok, admin: admin}
  end

  test "admins see the overview, compared with the period before", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/dashboard?period=7")
    |> assert_has("h1", text: "Dashboard")
    |> assert_has("#stat-topics .stat-value", text: "1")
    |> assert_has("#stat-topics", text: "new")
    |> assert_has("#stat-review_queue")
    |> assert_has("#stat-storage", text: "0 B")
    |> assert_has("#version", text: "Firefly")
    |> assert_has("#chart-signups svg rect.bar")
    |> assert_has("#period a.btn-active", text: "7 days")
    |> click_button("Refresh")
    |> assert_has("#stat-topics .stat-value", text: "1")
  end

  test "a custom range", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/dashboard?from=2020-01-01&to=2020-01-31")
    |> assert_has("#stat-topics .stat-value", text: "0")
    |> assert_has("p", text: "2020-01-01 to 2020-01-31")
  end

  test "the staff nav links to it", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/")
    |> click_link("nav a", "Dashboard")
    |> assert_path(~p"/staff/dashboard")
  end

  test "members can't see it", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/dashboard")
    |> assert_path(~p"/")

    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/reports/signups")
    |> assert_path(~p"/")

    assert conn
           |> log_in_as(user_fixture())
           |> get(~p"/staff/reports/signups/export")
           |> redirected_to() == "/"
  end

  test "reports: list, chart or table, CSV", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/reports")
    |> assert_has("#reports li", count: 20)
    |> click_link("Topics with no response")
    |> assert_has("#result table td", text: "Counted")
    |> visit(~p"/staff/reports/topics?period=7")
    |> assert_has("#totals", text: "Topics: 1")
    |> assert_has("#result svg rect.bar")
    |> visit(~p"/staff/reports/page_views")
    |> assert_has("#result figure li", text: "Crawlers")

    today = Date.to_iso8601(Date.utc_today())

    conn =
      conn |> log_in_as(admin) |> get(~p"/staff/reports/topics/export?from=#{today}&to=#{today}")

    assert response(conn, 200) == "Date,Topics\r\n#{today},1\r\n"
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
  end

  test "an unknown report", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/reports/nope")
    |> assert_path(~p"/staff/reports")
  end
end
