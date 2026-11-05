defmodule FireflyWeb.OpenTelemetryTest do
  # Not async: spans and metrics are collected node-wide.
  use FireflyWeb.ConnCase, async: false

  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias OtelMetricExporter.Opentelemetry.Proto.Metrics.V1.{Gauge, Histogram, Sum}

  @root Path.expand("../../..", __DIR__)

  describe "traces" do
    setup do
      # Ended spans come here when flushed (see spans/0); once this test's
      # process is gone, sending them is a no-op.
      :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
      FireflyWeb.OpenTelemetry.instrument()
      on_exit(&uninstrument/0)
    end

    test "an HTTP request is a server span, with its Ecto queries as children" do
      category_fixture()
      port = FireflyWeb.Endpoint.config(:http)[:port]

      assert %{status: 200} = Req.get!("http://127.0.0.1:#{port}/", retry: false)

      # Bandit's span is the root; it ends once the response is sent.
      root? = &(span(&1, :kind) == :server and span(&1, :parent_span_id) == :undefined)
      spans = spans(root?)
      server = Enum.find(spans, root?)

      assert span(server, :name) =~ "GET"
      assert attribute(server, :"http.response.status_code") == 200

      trace = Enum.filter(spans, &(span(&1, :trace_id) == span(server, :trace_id)))
      queries = Enum.filter(trace, &String.starts_with?(span(&1, :name), "firefly.repo.query"))
      assert queries != []

      # Every query descends from the request's span.
      ids = MapSet.new(trace, &span(&1, :span_id))
      assert Enum.all?(queries, &MapSet.member?(ids, span(&1, :parent_span_id)))
    end

    test "domain operations are spans, and background work joins their trace" do
      author = user_fixture()
      thread = thread_fixture(category_fixture(), author)

      Tracer.with_span "test" do
        {:ok, post} = Firefly.Discussion.create_post(thread, author, %{body: "A reply"})

        # The fan-out gets the caller's context with the message.
        message = {{:post_edited, post}, Firefly.Telemetry.current_context()}

        Task.async(fn -> Firefly.Notifications.Dispatcher.handle_cast(message, :nostate) end)
        |> Task.await()
      end

      spans = spans(&(span(&1, :name) == "test"))
      root = Enum.find(spans, &(span(&1, :name) == "test"))
      # Earlier tests leave their own spans in the exporter's queue; only this trace counts.
      in_trace = &(span(&1, :trace_id) == span(root, :trace_id))
      named = fn name -> Enum.find(spans, &(in_trace.(&1) and span(&1, :name) == name)) end
      post = named.("firefly.discussion.create_post")
      dispatch = named.("firefly.notifications.dispatch")

      assert span(post, :parent_span_id) == span(root, :span_id)
      assert attribute(post, "firefly.result") == "ok"
      assert span(dispatch, :trace_id) == span(root, :trace_id)
      assert attribute(dispatch, "firefly.event") == "post_edited"
    end

    test "a failing span records the exception" do
      assert_raise RuntimeError, fn ->
        Firefly.Telemetry.span([:firefly, :test, :failing], %{}, fn -> raise "boom" end)
      end

      failing? = &(span(&1, :name) == "firefly.test.failing")
      failed = Enum.find(spans(failing?), failing?)
      assert elem(span(failed, :status), 1) == :error
    end

    test "logs carry the trace and span ids, in bound tasks too" do
      Tracer.with_span "logging" do
        ctx = Tracer.current_span_ctx()
        trace_id = OpenTelemetry.Span.hex_trace_id(ctx)

        assert Logger.metadata()[:otel_trace_id] == trace_id
        assert Logger.metadata()[:otel_span_id] == OpenTelemetry.Span.hex_span_id(ctx)

        in_task =
          fn -> Logger.metadata()[:otel_trace_id] end
          |> Firefly.Telemetry.bind()
          |> Task.async()
          |> Task.await()

        assert in_task == trace_id
      end
    end
  end

  describe "logs over OTLP" do
    defmodule Collector do
      @moduledoc false
      @behaviour Plug
      def init(test), do: test

      def call(conn, test) do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:otlp, conn.request_path, body})
        Plug.Conn.send_resp(conn, 200, "")
      end
    end

    test "carry their trace and span ids" do
      collector = start_supervised!({Bandit, plug: {Collector, self()}, port: 0, ip: :loopback})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(collector)

      # The test config logs warnings and up.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      :ok =
        :logger.add_handler(:otel_logs_test, :otel_log_handler, %{
          level: :info,
          scheduled_delay_ms: 100,
          exporter:
            {:otel_exporter_logs_otlp,
             %{endpoints: ["http://127.0.0.1:#{port}"], protocol: :http_protobuf}}
        })

      on_exit(fn -> :logger.remove_handler(:otel_logs_test) end)

      {{trace_id, span_id}, _console} =
        ExUnit.CaptureLog.with_log(fn ->
          Tracer.with_span "logged" do
            Logger.info("exported with its trace")
            ctx = Tracer.current_span_ctx()
            {OpenTelemetry.Span.trace_id(ctx), OpenTelemetry.Span.span_id(ctx)}
          end
        end)

      assert_receive {:otlp, "/v1/logs", body}, 5_000
      # Protobuf: the message as is, the ids as raw bytes.
      assert body =~ "exported with its trace"
      assert body =~ <<trace_id::128>>
      assert body =~ <<span_id::64>>
    end
  end

  describe "metrics over OTLP" do
    setup do
      collector =
        start_supervised!({Bandit, plug: {__MODULE__.Collector, self()}, port: 0, ip: :loopback})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(collector)

      # What config/runtime.exs sets from the OTEL_* variables.
      Application.put_env(:otel_metric_exporter, :otlp_endpoint, "http://127.0.0.1:#{port}")
      Application.put_env(:otel_metric_exporter, :export_period, 100)

      on_exit(fn ->
        Application.delete_env(:otel_metric_exporter, :otlp_endpoint)
        Application.delete_env(:otel_metric_exporter, :export_period)
      end)
    end

    test "report the Prometheus metric definitions, with their tags and buckets" do
      start_supervised!(FireflyWeb.Telemetry.exporter_spec())

      Firefly.Telemetry.execute([:firefly, :notifications, :created], %{count: 1}, %{
        kind: "mentioned"
      })

      Firefly.Telemetry.span([:firefly, :scheduler, :job], %{job: "Firefly.Badges"}, fn ->
        {:ok, %{}}
      end)

      Firefly.Telemetry.execute([:firefly, :queue, :depth], %{depth: 3}, %{queue: "webhooks"})

      metrics =
        receive_metrics(~w(firefly.notifications.created.count
                           firefly.scheduler.job.stop.duration.microseconds
                           firefly.queue.depth))

      # The traces' resource.
      resource = FireflyWeb.OpenTelemetry.resource()
      assert metrics.resource["service.name"] == resource["service.name"]
      assert metrics.resource["service.instance.id"] == resource["service.instance.id"]
      assert is_binary(resource["service.name"])

      assert {:sum, %Sum{is_monotonic: true, data_points: [created]}} =
               metrics["firefly.notifications.created.count"].data

      assert attributes(created) == %{"kind" => "mentioned"}
      assert created.value == {:as_int, 1}

      job = metrics["firefly.scheduler.job.stop.duration.microseconds"]
      assert job.unit == "us"
      assert {:histogram, %Histogram{data_points: [point]}} = job.data
      assert attributes(point) == %{"job" => "Firefly.Badges"}
      assert point.count == 1
      assert Enum.sum(point.bucket_counts) == 1

      # Prometheus' buckets (Peep's upper bounds, the last one +Inf).
      buckets = FireflyWeb.Telemetry.Buckets

      peep_bounds =
        for index <- 0..(buckets.number_of_buckets(%{}) - 1),
            do: index |> buckets.upper_bound(%{}) |> String.to_float()

      assert point.explicit_bounds == peep_bounds
      assert length(point.bucket_counts) == length(peep_bounds) + 1

      assert {:gauge, %Gauge{data_points: [depth]}} = metrics["firefly.queue.depth"].data
      assert attributes(depth) == %{"queue" => "webhooks"}
      assert depth.value == {:as_int, 3}
    end

    test "a query without a queue time leaves the query metrics reporting" do
      FireflyWeb.Telemetry.attach_queue_time()
      on_exit(fn -> :telemetry.detach({FireflyWeb.Telemetry, :queue_time}) end)
      start_supervised!(FireflyWeb.Telemetry.exporter_spec())

      ms = System.convert_time_unit(1, :millisecond, :native)
      :telemetry.execute([:firefly, :repo, :query], %{total_time: ms}, %{source: "otel_test"})

      :telemetry.execute([:firefly, :repo, :query], %{total_time: 3 * ms, queue_time: 2 * ms}, %{
        source: "otel_test"
      })

      metrics =
        receive_metrics(~w(firefly.repo.query.total_time.microseconds
                           firefly.repo.query.queue_time.microseconds))

      # Points may come in more than one export.
      {:histogram, %Histogram{data_points: points}} =
        metrics["firefly.repo.query.total_time.microseconds"].data

      ours = Enum.filter(points, &(attributes(&1) == %{"source" => "otel_test"}))
      assert ours |> Enum.map(& &1.count) |> Enum.sum() == 2

      {:histogram, %Histogram{data_points: queued}} =
        metrics["firefly.repo.query.queue_time.microseconds"].data

      assert queued |> Enum.map(& &1.count) |> Enum.sum() == 1
      assert queued |> Enum.map(& &1.sum) |> Enum.sum() == 2_000.0
    end
  end

  describe "configuration" do
    setup do
      vars = ~w(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
                OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL
                OTEL_EXPORTER_OTLP_METRICS_PROTOCOL OTEL_EXPORTER_OTLP_HEADERS
                OTEL_EXPORTER_OTLP_METRICS_HEADERS OTEL_EXPORTER_OTLP_TIMEOUT
                OTEL_EXPORTER_OTLP_METRICS_TIMEOUT OTEL_METRIC_EXPORT_INTERVAL
                OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER FIREFLY_OTEL_METRICS FIREFLY_OTEL_LOGS)

      saved = Map.new(vars, &{&1, System.get_env(&1)})
      Enum.each(vars, &System.delete_env/1)

      on_exit(fn ->
        for {var, value} <- saved,
            do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
      end)
    end

    defp runtime_config,
      do: Config.Reader.read!(Path.join(@root, "config/runtime.exs"), env: :dev)

    test "nothing is exported without an endpoint" do
      config = Config.Reader.read!(Path.join(@root, "config/config.exs"), env: :prod)
      assert config[:opentelemetry][:traces_exporter] == :none

      runtime = runtime_config()

      assert runtime[:firefly_web][FireflyWeb.OpenTelemetry] == [
               traces: false,
               metrics: false,
               logs: false
             ]

      refute runtime[:opentelemetry][:traces_exporter]
      refute runtime[:otel_metric_exporter]

      # Opting into metrics and logs isn't enough either.
      System.put_env("FIREFLY_OTEL_METRICS", "true")
      System.put_env("FIREFLY_OTEL_LOGS", "true")
      refute runtime_config()[:firefly_web][FireflyWeb.OpenTelemetry][:metrics]
    end

    test "an endpoint turns traces on; metrics and logs need their opt-in" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")

      runtime = runtime_config()

      assert runtime[:firefly_web][FireflyWeb.OpenTelemetry] == [
               traces: true,
               metrics: false,
               logs: false
             ]

      assert runtime[:opentelemetry][:traces_exporter] == :otlp

      System.put_env("FIREFLY_OTEL_METRICS", "true")
      System.put_env("FIREFLY_OTEL_LOGS", "1")
      runtime = runtime_config()

      assert runtime[:firefly_web][FireflyWeb.OpenTelemetry] == [
               traces: true,
               metrics: true,
               logs: true
             ]

      assert runtime[:otel_metric_exporter] == [
               otlp_endpoint: "http://collector:4318",
               otlp_headers: %{},
               otlp_timeout: 10_000,
               export_period: 60_000
             ]

      System.put_env("OTEL_TRACES_EXPORTER", "none")
      System.put_env("OTEL_METRICS_EXPORTER", "none")
      runtime = runtime_config()
      refute runtime[:firefly_web][FireflyWeb.OpenTelemetry][:traces]
      refute runtime[:firefly_web][FireflyWeb.OpenTelemetry][:metrics]
      refute runtime[:otel_metric_exporter]
    end

    test "the metrics exporter gets the OTEL_* variables as the SDK reads them" do
      System.put_env("FIREFLY_OTEL_METRICS", "true")
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4317")
      System.put_env("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")

      # Only http/protobuf: a clear error rather than metrics lost.
      assert_raise RuntimeError, ~r/http\/protobuf only/, &runtime_config/0

      # The signal's own variables win; its endpoint is the full URL.
      System.put_env("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", "http/protobuf")

      System.put_env(
        "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
        "https://otlp.example/otlp/v1/metrics"
      )

      System.put_env("OTEL_EXPORTER_OTLP_HEADERS", "x-ignored=1")

      System.put_env(
        "OTEL_EXPORTER_OTLP_METRICS_HEADERS",
        "authorization=Basic dXNlcjpwYXNz==, x-team = forum"
      )

      System.put_env("OTEL_EXPORTER_OTLP_METRICS_TIMEOUT", "5000")
      System.put_env("OTEL_METRIC_EXPORT_INTERVAL", "15000")

      assert runtime_config()[:otel_metric_exporter] == [
               otlp_endpoint: "https://otlp.example/otlp",
               otlp_headers: %{"authorization" => "Basic dXNlcjpwYXNz==", "x-team" => "forum"},
               otlp_timeout: 5_000,
               export_period: 15_000
             ]
    end
  end

  # The spans ended so far, once one matching `until` has: flushes the
  # batch processor until it's there.
  defp spans(until, acc \\ [], tries \\ 50) do
    :otel_tracer_provider.force_flush()
    acc = acc ++ receive_all()

    cond do
      Enum.any?(acc, until) -> acc
      tries == 0 -> flunk("no matching span")
      true -> spans(until, acc, tries - 1)
    end
  end

  defp receive_all do
    receive do
      {:span, span} -> [span | receive_all()]
    after
      100 -> []
    end
  end

  # Detaches what FireflyWeb.OpenTelemetry.instrument/0 attached.
  defp uninstrument do
    instrumentation = [OpentelemetryBandit, OpentelemetryPhoenix, OpentelemetryEcto]

    for %{id: id, function: fun} <- :telemetry.list_handlers([]),
        Function.info(fun)[:module] in instrumentation,
        do: :telemetry.detach(id)
  end

  # The metrics named, by name, with their data points from every export
  # the collector receives until they're all in, and the next one (for
  # points recorded across an export), and the resource they came with.
  defp receive_metrics(names, acc \\ %{}) do
    receive do
      {:otlp, "/v1/metrics", body} ->
        %{resource_metrics: [%{resource: resource, scope_metrics: scopes}]} =
          body |> :zlib.gunzip() |> ExportMetricsServiceRequest.decode()

        all_in? = Enum.all?(names, &Map.has_key?(acc, &1))

        acc =
          for %{metrics: metrics} <- scopes, metric <- metrics, reduce: acc do
            acc -> Map.update(acc, metric.name, metric, &merge_points(&1, metric))
          end
          |> Map.put(:resource, attributes(resource))

        if all_in?, do: acc, else: receive_metrics(names, acc)
    after
      5_000 -> flunk("no metrics #{inspect(names -- Map.keys(acc))}")
    end
  end

  defp merge_points(%{data: {type, data}} = metric, %{data: {type, more}}),
    do: %{metric | data: {type, %{data | data_points: data.data_points ++ more.data_points}}}

  defp attributes(%{attributes: attributes}),
    do: Map.new(attributes, fn %{key: key, value: %{value: {_type, value}}} -> {key, value} end)

  defp attribute(span, key), do: :otel_attributes.map(span(span, :attributes))[key]
end
