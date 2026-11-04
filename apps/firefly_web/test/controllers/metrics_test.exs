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

    test "reports the VM, web, database, domain and cluster metrics, by node", %{conn: conn} do
      category = category_fixture()
      thread = thread_fixture(category, user_fixture())
      path = "/categories/#{category.id}/threads/#{thread.id}"
      conn |> get(path) |> html_response(200)

      :telemetry.execute([:vm, :memory], %{total: 1024, processes: 1, binary: 1, ets: 1}, %{})
      :telemetry.execute([:vm, :system_counts], %{process_count: 42, port_count: 3}, %{})
      Firefly.Telemetry.measure_queues()

      Firefly.Telemetry.execute([:firefly, :cluster, :node], %{count: 1, connected: 2}, %{
        event: :up,
        node: :"firefly@10.0.0.8"
      })

      Firefly.Telemetry.span([:firefly, :scheduler, :job], %{job: "Firefly.Badges"}, fn ->
        {:ok, %{}}
      end)

      body =
        conn
        |> put_req_header("authorization", "Bearer s3cret")
        |> get("/metrics")
        |> response(200)

      # Every series names the node it was measured on.
      node = ~s{node="#{node()}"}
      assert body =~ ~s|vm_memory_total{#{node}} 1024|
      assert body =~ ~s|vm_system_counts_process_count{#{node}} 42|
      assert body =~ ~s|firefly_queue_depth{#{node},queue="plugin_events"} 0|
      assert body =~ ~s|firefly_queue_depth{#{node},queue="webhooks"} 0|
      assert body =~ "firefly_repo_query_total_time_microseconds_bucket"

      assert body =~
               ~s|firefly_scheduler_job_stop_duration_microseconds_count{job="Firefly.Badges",#{node}} 1|

      assert body =~ ~s|firefly_cluster_node_count{event="up",#{node}} 1|
      assert body =~ ~s|firefly_cluster_nodes_connected{#{node}} 2|

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
