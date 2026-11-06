defmodule FireflyWeb.JailTest do
  # The jail's ETS tables are per node, shared by every test.
  use FireflyWeb.ConnCase, async: false

  @moduletag :capture_log

  import FireflyPlugins.PluginHelpers

  alias Firefly.{Plugins, Repo}
  alias Firefly.Plugin.Runner
  alias Firefly.Plugins.EventWorker
  alias Firefly.Security.{Ban, Jail}

  setup do
    config = Application.get_env(:firefly, Jail)
    Application.put_env(:firefly, Jail, enabled: true, trusted_proxies: [])
    Jail.reset()

    on_exit(fn ->
      Application.put_env(:firefly, Jail, config)
      Jail.reset()
    end)

    {:ok, admin: admin_fixture()}
  end

  defp from(conn, ip), do: %{conn | remote_ip: ip}

  describe "the plug" do
    test "answers banned addresses with a minimal 403, before the session", %{
      conn: conn,
      admin: admin
    } do
      {:ok, _} = Jail.ban("203.0.113.9", admin, minutes: 10)

      conn = conn |> from({203, 0, 113, 9}) |> get(~p"/")
      assert conn.status == 403
      assert conn.resp_body =~ "Access denied"
      assert [seconds] = get_resp_header(conn, "retry-after")
      assert String.to_integer(seconds) in 590..600
      assert get_resp_header(conn, "set-cookie") == []

      assert build_conn() |> from({203, 0, 113, 10}) |> get(~p"/") |> html_response(200)
    end

    test "leaves health checks alone", %{conn: conn, admin: admin} do
      {:ok, _} = Jail.ban("203.0.113.11", admin)
      assert conn |> from({203, 0, 113, 11}) |> get("/health") |> response(200)
    end
  end

  describe "signals from requests" do
    test "exploit probes get a 404 and a ban after a few", %{conn: conn} do
      ip = {198, 51, 100, 20}

      for path <- ["/wp-login.php", "/.env"] do
        conn = build_conn() |> from(ip) |> get(path)
        assert conn.status == 404
      end

      refute Jail.banned(ip)
      assert conn |> from(ip) |> get("/.git/config") |> response(404)
      assert Jail.banned(ip)
      assert build_conn() |> from(ip) |> get(~p"/") |> response(403)
    end

    test "ordinary 404s count a little", %{conn: conn} do
      ip = {198, 51, 100, 21}
      assert conn |> from(ip) |> get("/no/such/page") |> response(404)
      assert [%{key: "198.51.100.21", jail: "probe", points: 1}] = Jail.offenders()
    end

    test "CSRF failures count in the csrf jail" do
      # ConnTest skips CSRF checks, so the plug is called on a bare conn.
      conn =
        Plug.Test.conn(:post, "/confirm", %{})
        |> from({198, 51, 100, 22})
        |> Plug.Test.init_test_session(%{})

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        FireflyWeb.Plugs.CSRF.call(conn, FireflyWeb.Plugs.CSRF.init([]))
      end

      assert [%{jail: "csrf", points: 1}] = Jail.offenders()
    end

    test "bad API keys count in the auth jail", %{conn: conn} do
      conn
      |> from({198, 51, 100, 23})
      |> put_req_header("authorization", "Bearer nope")
      |> get("/api/v1/categories")

      assert [%{jail: "auth", key: "198.51.100.23"}] = Jail.offenders()
    end
  end

  describe "staff" do
    test "ban, see and unban addresses at /staff/security", %{conn: conn, admin: admin} do
      Jail.signal("192.0.2.30", "login_failure")

      session =
        conn
        |> log_in_as(admin)
        |> visit(~p"/staff/security")
        |> assert_has("#bans-empty")
        |> assert_has("#offenders td", text: "192.0.2.30")
        |> fill_in("IP address or range", with: "192.0.2.0/24")
        |> select("For", option: "1 day")
        |> fill_in("Reason", with: "spam wave")
        |> click_button("Ban")
        |> assert_has("#active-bans td", text: "192.0.2.0/24")
        |> assert_has("#active-bans td", text: "spam wave")

      assert Jail.banned("192.0.2.30")
      ban = Repo.get_by!(Ban, ip: "192.0.2.0/24")

      session
      |> click_button("#ban-#{ban.id} button", "Unban")
      |> assert_has("#bans-empty")

      refute Jail.banned("192.0.2.30")
    end
  end

  describe "plugins" do
    test "report addresses with jail.signal, rate-limited, and hear of bans", %{admin: admin} do
      install_plugin!(
        admin,
        %{
          "id" => "guard",
          "name" => "Guard",
          "exports" => ["go"],
          "hooks" => ["handle_event"],
          "events" => ["ip_banned", "ip_unbanned"],
          "permissions" => ["security"]
        },
        %{
          "index.js" => """
          exports.go = (args) => firefly.call('jail.signal', {ip: args.ip, reason: 'credential stuffing'});
          exports.handle_event = () => null;
          """
        },
        enable: true
      )

      go = fn ip ->
        Runner.invoke(Plugins.get_active("guard"), "call_export", ["go", %{"ip" => ip}])
      end

      for _ <- 1..19, do: assert({:ok, %{"banned" => false}} = go.("203.0.113.77"))
      assert {:ok, %{"banned" => true}} = go.("203.0.113.77")
      assert %{jail: "plugin"} = Jail.banned("203.0.113.77")
      assert {:error, {:js_error, "ip must be an IP address" <> _}} = go.("not an ip")

      assert_enqueued(
        worker: EventWorker,
        args: %{
          plugin_id: "guard",
          event: "ip_banned",
          payload: %{ip: "203.0.113.77", jail: "plugin"}
        }
      )
    end

    test "only plugins with the security permission may hear of bans" do
      manifest = %{
        "id" => "nosy",
        "name" => "Nosy",
        "version" => "1.0.0",
        "firefly" => ">= 0.1.0",
        "hooks" => ["handle_event"],
        "events" => ["ip_banned"],
        "permissions" => ["read"]
      }

      assert {:error, message} = Firefly.Plugin.Manifest.parse(manifest, "upload")
      assert message =~ "need the security permission"
      refute message =~ "needs the read permission"

      assert {:ok, _} =
               Firefly.Plugin.Manifest.parse(
                 %{manifest | "permissions" => ["security"]},
                 "upload"
               )
    end
  end
end
