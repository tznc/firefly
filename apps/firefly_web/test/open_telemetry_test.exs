defmodule FireflyWeb.OpenTelemetryTest do
  # Not async: spans and metrics are collected node-wide.
  use FireflyWeb.ConnCase, async: false

  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @metrics_hrl "opentelemetry_experimental/include/otel_metrics.hrl"
  Record.defrecordp(:metric, Record.extract(:metric, from_lib: @metrics_hrl))
  Record.defrecordp(:sum, Record.extract(:sum, from_lib: @metrics_hrl))
  Record.defrecordp(:datapoint, Record.extract(:datapoint, from_lib: @metrics_hrl))
  Record.defrecordp(:histogram, Record.extract(:histogram, from_lib: @metrics_hrl))

  Record.defrecordp(
    :histogram_datapoint,
    Record.extract(:histogram_datapoint, from_lib: @metrics_hrl)
  )

  @root Path.expand("../../..", __DIR__)

  defmodule Noop do
    @moduledoc false
    use Oban.Worker, queue: :default
    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  describe "traces" do
    setup do
      # Ended spans come here when flushed (see spans/0); once this test's
      # process is gone, sending them is a no-op.
      # Spans other tests left unexported go to the old exporter first.
      :otel_tracer_provider.force_flush()
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
      # The flush also brings spans other tests ended: this trace's only.
      trace = Enum.filter(spans, &(span(&1, :trace_id) == span(root, :trace_id)))
      post = Enum.find(trace, &(span(&1, :name) == "firefly.discussion.create_post"))
      dispatch = Enum.find(trace, &(span(&1, :name) == "firefly.notifications.dispatch"))

      assert span(post, :parent_span_id) == span(root, :span_id)
      assert attribute(post, "firefly.result") == "ok"
      assert span(dispatch, :trace_id) == span(root, :trace_id)
      assert attribute(dispatch, "firefly.event") == "post_edited"
    end

    test "a background job joins its enqueuer's trace" do
      Tracer.with_span "enqueue" do
        {:ok, _job} = Firefly.Jobs.insert(Noop.new(%{}))
      end

      assert %{success: 1} = Oban.drain_queue(queue: :default)

      job? = &(span(&1, :name) == "process default")
      spans = spans(job?)
      root = Enum.find(spans, &(span(&1, :name) == "enqueue"))
      job = Enum.find(spans, job?)

      assert span(job, :trace_id) == span(root, :trace_id)
      assert span(job, :kind) == :consumer
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
    test "report the Prometheus metric definitions" do
      # The test config's metric reader sends to this name on a flush.
      Process.register(self(), :firefly_otel_metrics_test)

      start_supervised!({FireflyWeb.OpenTelemetry.Metrics, FireflyWeb.Telemetry.metrics()})

      Firefly.Telemetry.execute([:firefly, :notifications, :created], %{count: 1}, %{
        kind: "mentioned"
      })

      Firefly.Telemetry.span([:firefly, :scheduler, :job], %{job: "Firefly.Badges"}, fn ->
        {:ok, %{}}
      end)

      :otel_meter_server.force_flush()

      created = receive_metric(:"firefly.notifications.created.count")

      assert [datapoint(attributes: %{"kind" => "mentioned"}, value: 1)] =
               sum(metric(created, :data), :datapoints)

      job = receive_metric(:"firefly.scheduler.job.stop.duration.microseconds")

      assert [histogram_datapoint(attributes: %{"job" => "Firefly.Badges"}, count: 1) = point] =
               histogram(metric(job, :data), :datapoints)

      assert hd(histogram_datapoint(point, :explicit_bounds)) == 500.0
    end
  end

  describe "configuration" do
    setup do
      vars = ~w(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
                OTEL_TRACES_EXPORTER FIREFLY_OTEL_METRICS FIREFLY_OTEL_LOGS)

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
      refute runtime[:opentelemetry_experimental]

      # Opting into the experimental signals isn't enough either.
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

      assert [%{module: :otel_metric_reader}] = runtime[:opentelemetry_experimental][:readers]

      System.put_env("OTEL_TRACES_EXPORTER", "none")
      refute runtime_config()[:firefly_web][FireflyWeb.OpenTelemetry][:traces]
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
    instrumentation = [
      OpentelemetryBandit,
      OpentelemetryPhoenix,
      OpentelemetryEcto,
      OpentelemetryOban.JobHandler,
      OpentelemetryOban.PluginHandler
    ]

    for %{id: id, function: fun} <- :telemetry.list_handlers([]),
        Function.info(fun)[:module] in instrumentation,
        do: :telemetry.detach(id)
  end

  defp receive_metric(name) do
    receive do
      {:otel_metric, metric(name: ^name) = metric} -> metric
    after
      5_000 -> flunk("no metric #{name}")
    end
  end

  defp attribute(span, key), do: :otel_attributes.map(span(span, :attributes))[key]
end
