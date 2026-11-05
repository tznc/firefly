defmodule FireflyWeb.UpgradesTest do
  # Changes global config (the GitHub API's address, local addresses allowed).
  use FireflyWeb.ConnCase, async: false

  import Ecto.Query

  alias Firefly.{Repo, SiteSettings, Upgrades}
  alias Firefly.Notifications.Notification
  alias Firefly.Plugins.HTTP

  # A fake GitHub API: the latest release, with an ETag.
  defmodule GitHub do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/repos/tznc/firefly/releases/latest"} = conn, test) do
      send(
        test,
        {:github, get_req_header(conn, "if-none-match"), get_req_header(conn, "user-agent")}
      )

      release = :persistent_term.get({__MODULE__, :release})

      if get_req_header(conn, "if-none-match") == [~s{"#{release["tag_name"]}"}] do
        send_resp(conn, 304, "")
      else
        conn
        |> put_resp_header("etag", ~s{"#{release["tag_name"]}"})
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(release))
      end
    end

    def call(conn, _test), do: send_resp(conn, 404, ~s({"message": "Not Found"}))
  end

  defp release(tag) do
    :persistent_term.put({GitHub, :release}, %{
      "tag_name" => tag,
      "name" => "Firefly #{tag}",
      "body" => "## Highlights\n\n* Faster\n\n<script>alert(1)</script>",
      "html_url" => "https://github.com/tznc/firefly/releases/tag/#{tag}",
      "published_at" => "2026-11-01T12:00:00Z"
    })
  end

  setup do
    {:ok, server} =
      start_supervised({Bandit, plug: {GitHub, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    http = Application.get_env(:firefly, HTTP, [])
    upgrades = Application.get_env(:firefly, Upgrades, [])
    Application.put_env(:firefly, HTTP, allow_private: [{127, 0, 0, 1}])

    Application.put_env(:firefly, Upgrades,
      api_url: "http://127.0.0.1:#{port}",
      git_sha: "abc123def4567890"
    )

    on_exit(fn ->
      Application.put_env(:firefly, HTTP, http)
      Application.put_env(:firefly, Upgrades, upgrades)
    end)

    release("v99.0.0")
    {:ok, admin: admin_fixture()}
  end

  test "versions compare by semver" do
    assert Upgrades.newer?("v1.2.10", "1.2.9")
    refute Upgrades.newer?("1.2.9", "1.2.9")
    refute Upgrades.newer?("v1.0.0", "1.2.9")
    refute Upgrades.newer?("nightly", "1.2.9")
    refute Upgrades.newer?(nil, "1.2.9")
  end

  test "the check finds the latest release, then asks with its ETag" do
    assert {:ok, status} = Upgrades.check()
    assert_received {:github, [], ["Firefly/" <> _]}
    assert %{latest: "v99.0.0", name: "Firefly v99.0.0", update?: true} = status
    assert status.notes_html =~ "<h2>"
    refute status.notes_html =~ "<script"
    assert status.git_sha == "abc123def4567890"
    assert Upgrades.update_available?()

    assert {:ok, %{latest: "v99.0.0"}} = Upgrades.check()
    assert_received {:github, [~s{"v99.0.0"}], _}
  end

  test "an older or missing release isn't an update; failures are kept" do
    release("v0.0.1")
    assert {:ok, %{update?: false, latest: "v0.0.1"}} = Upgrades.check()

    Application.put_env(:firefly, Upgrades,
      api_url: Application.get_env(:firefly, Upgrades)[:api_url],
      repo: "tznc/nothing"
    )

    assert {:ok, %{latest: nil, update?: false}} = Upgrades.check()

    # Private addresses are refused like any other outgoing request.
    Application.put_env(:firefly, HTTP, allow_private: false)
    assert {:error, message} = Upgrades.check()
    assert Upgrades.status().error == message
  end

  test "the daily job checks, and notifies admins once per release", %{admin: admin} do
    assert {"23 4 * * *", Firefly.Jobs.Periodic.VersionCheck} in Firefly.Jobs.crontab()
    assert :ok = perform_job(Firefly.Jobs.Periodic.VersionCheck, %{})
    assert_received {:github, _, _}

    notifications = Repo.all(from(n in Notification, where: n.user_id == ^admin.id))
    assert [%{kind: "new_version", subject: "Firefly v99.0.0 is out"}] = notifications

    # The next day, the same release: no new notification.
    Upgrades.run_due()
    assert_received {:github, _, _}
    assert Repo.aggregate(from(n in Notification, where: n.kind == "new_version"), :count) == 1
  end

  test "the setting turns the check off", %{admin: admin} do
    {:ok, _} = SiteSettings.update(%{"version_check" => "false"}, admin)
    Upgrades.run_due()
    refute_received {:github, _, _}
  end

  test "the dashboard and upgrade page show the new version", %{conn: conn, admin: admin} do
    {:ok, _} = Upgrades.check()

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/dashboard")
    |> assert_has("#version", text: "abc123def456")
    |> assert_has("#update-available", text: "v99.0.0")
    |> assert_has("#update-badge")
    |> click_link("#update-available a", "How to upgrade")
    |> assert_path(~p"/staff/upgrade")
    |> assert_has("#release-notes h2", text: "Highlights")
    |> assert_has("#pending-migrations", text: "up to date")
    |> assert_has("#steps-docker", text: "Firefly.Release.migrate")
    |> assert_has("#steps-docker a", text: "Make a backup")
    |> click_button("Check now")
    |> assert_has("#flash-info", text: "Checked.")
  end

  test "members can't see the upgrade page", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/upgrade")
    |> assert_path(~p"/")
  end
end
