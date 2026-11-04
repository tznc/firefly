defmodule FireflyWeb.MetricsTest do
  # Not async: the metrics config is node-wide.
  use FireflyWeb.ConnCase, async: false

  alias FireflyWeb.Metrics

  setup do
    on_exit(fn -> Application.delete_env(:firefly_web, Metrics) end)
  end

  defp configure(config), do: Application.put_env(:firefly_web, Metrics, config)

  describe "off by default" do
    test "nothing is collected or served", %{conn: conn} do
      refute Metrics.enabled?()
      assert Metrics.listener_specs() == []
      refute Process.whereis(:firefly_metrics)
      assert FireflyWeb.Telemetry.prometheus() == nil

      assert conn |> get("/metrics") |> Map.get(:status) == 404
    end
  end

  describe "on the main endpoint, with a token" do
    setup do
      configure(token: "s3cret")
      start_supervised!(FireflyWeb.Telemetry.reporter_spec())
      :ok
    end

    test "requires the bearer token", %{conn: conn} do
      assert Metrics.enabled?()
      assert conn |> get("/metrics") |> response(401) == "unauthorized\n"

      assert conn
             |> put_req_header("authorization", "Bearer wrong")
             |> get("/metrics")
             |> response(401)

      body =
        conn
        |> put_req_header("authorization", "Bearer s3cret")
        |> get("/metrics")
        |> response(200)

      assert body =~ "# EOF"
    end

    test "reports the VM, web, database and domain metrics", %{conn: conn} do
      category = category_fixture()
      thread = thread_fixture(category, user_fixture())
      path = "/categories/#{category.id}/threads/#{thread.id}"
      conn |> get(path) |> html_response(200)

      :telemetry.execute([:vm, :memory], %{total: 1024, processes: 1, binary: 1, ets: 1}, %{})
      :telemetry.execute([:vm, :system_counts], %{process_count: 42, port_count: 3}, %{})
      Firefly.Telemetry.measure_queues()

      {:ok, _} =
        Firefly.Mailer.deliver_now(Firefly.Notifications.Emails.test_email("ops@example.com"))

      Firefly.Telemetry.span([:firefly, :scheduler, :job], %{job: "Firefly.Badges"}, fn ->
        {:ok, %{}}
      end)

      body =
        conn
        |> put_req_header("authorization", "Bearer s3cret")
        |> get("/metrics")
        |> response(200)

      assert body =~ ~S|vm_memory_total 1024|
      assert body =~ ~S|vm_system_counts_process_count 42|
      assert body =~ ~S|firefly_mailer_deliver_stop_count{adapter="test",result="sent"} 1|
      assert body =~ ~S|firefly_queue_depth{queue="plugin_events"} 0|
      assert body =~ ~S|firefly_queue_depth{queue="webhooks"} 0|
      assert body =~ "firefly_repo_query_total_time_microseconds_bucket"

      assert body =~
               ~S|firefly_scheduler_job_stop_duration_microseconds_count{job="Firefly.Badges"} 1|

      # Routes by pattern, not path.
      assert body =~ ~S|route="/categories/:category_id/threads/:id"|
      refute body =~ path
    end
  end

  describe "on a port of its own" do
    test "serves /metrics there, with the token if set" do
      configure(port: 0)
      start_supervised!(FireflyWeb.Telemetry.reporter_spec())
      [{Bandit, opts}] = Metrics.listener_specs()
      pid = start_supervised!({Bandit, Keyword.put(opts, :ip, {127, 0, 0, 1})})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      url = "http://127.0.0.1:#{port}"

      assert %{status: 200, body: body} = Req.get!(url <> "/metrics", retry: false)
      assert body =~ "# EOF"
      assert %{status: 404} = Req.get!(url <> "/", retry: false)

      configure(port: 0, token: "s3cret")
      assert %{status: 401} = Req.get!(url <> "/metrics", retry: false)
      assert %{status: 200} = Req.get!(url <> "/metrics", auth: {:bearer, "s3cret"}, retry: false)
    end
  end
end
