defmodule FireflyWeb.BackupsLiveTest do
  # Backups run in their own process and read-only mode is global.
  use FireflyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest,
    only: [live: 2, render: 1, render_click: 1, render_submit: 2, element: 2, element: 3]

  alias Firefly.Backups
  alias Firefly.Backups.Store

  setup do
    File.rm_rf!(Store.dir())
    on_exit(fn -> Backups.set_read_only(nil) end)
    {:ok, admin: admin_fixture()}
  end

  test "back up now, see it live, download and delete it", %{conn: conn, admin: admin} do
    conn = log_in_as(conn, admin)
    Backups.subscribe()
    {:ok, view, _html} = live(conn, ~p"/staff/backups")

    view |> element("#create-backup") |> render_click()
    assert_receive {:backup_finished, :backup, {:ok, name}}, 60_000
    html = render(view)
    assert html =~ "Dumping the database"
    assert html =~ name

    {:error, {:redirect, %{to: "/staff/backups/download/" <> token}}} =
      view |> element("#backups li button", "Download") |> render_click()

    download = get(conn, ~p"/staff/backups/download/#{token}")
    assert response(download, 200) |> byte_size() > 0
    assert get_resp_header(download, "content-disposition") |> hd() =~ name

    {:ok, view, _html} = live(conn, ~p"/staff/backups")
    view |> element("#backups li button", "Delete") |> render_click()
    assert Backups.list() == []
  end

  test "restoring asks for the site's title", %{conn: conn, admin: admin} do
    File.mkdir_p!(Store.dir())
    File.write!(Path.join(Store.dir(), "firefly-2026-01-01-000000.tar.gz"), "x")

    {:ok, view, _html} = live(log_in_as(conn, admin), ~p"/staff/backups")
    view |> element("#backups li button", "Restore") |> render_click()

    html = render_submit(element(view, "#restore-form form"), %{"confirmation" => "Wrong"})
    assert html =~ "Type the site&#39;s title exactly to confirm."
    assert Backups.status().running == nil
  end

  test "read-only mode: banner, refused events and API writes, lifted on the backups page",
       %{conn: conn, admin: admin} do
    member = user_fixture()
    thread = thread_fixture(category_fixture(), user_fixture())

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/backups")
    |> click_button("Make read-only")
    |> assert_has("#read-only-banner", text: "read-only for maintenance")

    assert Backups.read_only?()

    {:ok, view, html} =
      live(log_in_as(conn, member), ~p"/categories/#{thread.category_id}/threads/#{thread}")

    assert html =~ "read-only for maintenance"
    html = view |> element("button[phx-click=flag]") |> render_click()
    assert html =~ "read-only for maintenance right now"

    api = conn |> put_req_header("accept", "application/json") |> post(~p"/api/v1/posts", %{})
    assert json_response(api, 503)["detail"] =~ "read-only"

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/backups")
    |> click_button("Turn off read-only mode")
    |> refute_has("#read-only-banner")

    refute Backups.read_only?()
  end

  test "members can't see backups or download them", %{conn: conn, admin: admin} do
    member = user_fixture()

    conn
    |> log_in_as(member)
    |> visit(~p"/staff/backups")
    |> assert_path(~p"/")

    token = Backups.download_token("firefly-2026-01-01-000000.tar.gz", admin)

    assert conn
           |> log_in_as(member)
           |> get(~p"/staff/backups/download/#{token}")
           |> redirected_to() == "/"
  end
end
