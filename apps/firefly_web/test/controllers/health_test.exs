defmodule FireflyWeb.HealthTest do
  use FireflyWeb.ConnCase, async: true

  alias Firefly.Repo

  test "GET /health is up without touching the session", %{conn: conn} do
    conn = get(conn, "/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
    # Answered before Plug.RequestId and Plug.Telemetry: probes aren't
    # logged or measured as requests.
    assert get_resp_header(conn, "x-request-id") == []
  end

  test "GET /ready reports every check", %{conn: conn} do
    body = conn |> get("/ready") |> json_response(200)

    assert body["status"] == "ready"

    assert %{
             "database" => %{"ok" => true},
             "migrations" => %{"ok" => true},
             "draining" => %{"ok" => true},
             "read_only" => %{"ok" => true, "enabled" => false},
             "plugin_sandbox" => %{"ok" => true, "available" => available},
             # Reported, never failing: clustering is off in tests.
             "cluster" => %{"ok" => true, "enabled" => false, "nodes" => 0}
           } = body["checks"]

    assert is_boolean(available)
    assert get_resp_header(conn |> get("/ready"), "set-cookie") == []
  end

  test "no database connection makes the node unready", %{conn: conn} do
    # A process the sandbox doesn't know gets no connection, as with a
    # database that's down.
    parent = self()
    spawn(fn -> send(parent, {:conn, get(conn, "/ready")}) end)
    assert_receive {:conn, conn}, 5_000

    body = json_response(conn, 503)
    assert body["status"] == "unavailable"
    assert body["failing"] == ["database", "migrations"]
    assert body["checks"]["database"]["ok"] == false
    assert is_binary(body["checks"]["database"]["error"])
  end

  test "a pending migration makes the node unready", %{conn: conn} do
    %{rows: [[version]]} = Repo.query!("SELECT max(version) FROM schema_migrations")
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])

    body = conn |> get("/ready") |> json_response(503)

    assert body["failing"] == ["migrations"]
    assert body["checks"]["migrations"]["pending"] == [version]
  end

  test "other methods and paths go on to the router", %{conn: conn} do
    assert conn |> post("/health") |> Map.get(:status) == 404
    assert conn |> get("/healthz") |> Map.get(:status) == 404
  end

  test "production's force_ssl lets probes over plain HTTP through", %{conn: conn} do
    prod = Config.Reader.read!(Path.expand("../../../../config/prod.exs", __DIR__))
    ssl = Plug.SSL.init(prod[:firefly_web][FireflyWeb.Endpoint][:force_ssl])
    conn = %{conn | host: "10.0.0.7"}

    probe = Plug.SSL.call(%{conn | request_path: "/ready", path_info: ["ready"]}, ssl)
    refute probe.halted

    page = Plug.SSL.call(%{conn | request_path: "/", path_info: []}, ssl)
    assert page.halted and page.status == 301
  end
end

defmodule FireflyWeb.HealthTest.NodeWide do
  # Not async: draining and read-only mode are node-wide.
  use FireflyWeb.ConnCase, async: false

  test "a draining node is unready, but alive", %{conn: conn} do
    FireflyWeb.Draining.put_draining(true)
    on_exit(fn -> FireflyWeb.Draining.put_draining(false) end)

    assert %{"failing" => ["draining"]} = conn |> get("/ready") |> json_response(503)
    assert conn |> get("/health") |> json_response(200)
  end

  test "read-only mode is reported but doesn't fail readiness", %{conn: conn} do
    :ok = Firefly.Backups.set_read_only("Upgrading")
    on_exit(fn -> Firefly.Backups.set_read_only(nil) end)

    body = conn |> get("/ready") |> json_response(200)
    assert body["checks"]["read_only"] == %{"ok" => true, "enabled" => true}
  end
end
