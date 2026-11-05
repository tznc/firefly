defmodule FireflyWeb.Telemetry do
  @moduledoc """
  The metrics Firefly reports (`metrics/0`) and, when metrics are on, the
  processes that collect them: for Prometheus (see `FireflyWeb.Metrics`), a
  Peep reporter aggregating them in memory; for OTLP (see
  `FireflyWeb.OpenTelemetry`), `OtelMetricExporter` pushing them to the
  collector; and for either, a poller measuring the VM and the background
  queues every 10 seconds. Both report the same definitions, histograms in
  the same buckets.

  Labels stay bounded: route patterns (never paths), LiveView modules (not
  their event names, which clients choose), the domain's event, job and
  plugin names, outcomes; never user ids. Every Prometheus series also
  carries the `node` it was measured on (one per node), so a cluster's
  nodes stay apart wherever they're scraped from.
  """
  use Supervisor

  import Telemetry.Metrics

  @reporter :firefly_metrics

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    prometheus? = FireflyWeb.Metrics.enabled?()
    otlp? = FireflyWeb.OpenTelemetry.enabled?(:metrics)

    if prometheus? or otlp?, do: attach_queue_time()

    children =
      if(prometheus?, do: [reporter_spec() | FireflyWeb.Metrics.listener_specs()], else: []) ++
        if(otlp?, do: [exporter_spec()], else: []) ++
        if prometheus? or otlp?, do: [poller_spec()], else: []

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The Peep reporter collecting `metrics/0`."
  def reporter_spec,
    do: {Peep, name: @reporter, metrics: metrics(), global_tags: %{node: node()}}

  @doc """
  The OTLP exporter pushing `metrics/0`, with the traces' resource (see
  `FireflyWeb.OpenTelemetry.resource/0`). The endpoint, headers and export
  period come from `config :otel_metric_exporter` (see `config/runtime.exs`).
  """
  def exporter_spec,
    do: {OtelMetricExporter, metrics: metrics(), resource: FireflyWeb.OpenTelemetry.resource()}

  # Ecto leaves :queue_time out when a query needed no connection checkout.
  # Peep skips a missing measurement but OtelMetricExporter doesn't (it
  # raises, and :telemetry then detaches the query's handler), so the
  # queue time is an event of its own, emitted only when measured.
  @doc false
  def attach_queue_time do
    :telemetry.attach(
      {__MODULE__, :queue_time},
      [:firefly, :repo, :query],
      &__MODULE__.handle_query/4,
      nil
    )
  end

  @doc false
  def handle_query(_event, %{queue_time: time}, metadata, _config),
    do: :telemetry.execute([:firefly, :repo, :queue], %{time: time}, metadata)

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp poller_spec do
    {:telemetry_poller,
     name: FireflyWeb.Telemetry.Poller,
     period: :timer.seconds(10),
     measurements: [
       :memory,
       :total_run_queue_lengths,
       :system_counts,
       {Firefly.Telemetry, :measure_queues, []}
     ]}
  end

  @doc "The collected metrics in Prometheus' text format, or nil when the reporter isn't running."
  @spec prometheus() :: iodata | nil
  def prometheus do
    if Process.whereis(@reporter),
      do: @reporter |> Peep.get_all_metrics() |> Peep.Prometheus.export()
  end

  @doc "Every metric reported, as `Telemetry.Metrics` definitions."
  def metrics do
    vm_metrics() ++ web_metrics() ++ repo_metrics() ++ domain_metrics()
  end

  defp vm_metrics do
    [
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.port_count")
    ]
  end

  defp web_metrics do
    [
      duration("phoenix.router_dispatch.stop.duration",
        tags: [:route, :method, :status],
        tag_values: &route_tags/1
      ),
      counter("phoenix.router_dispatch.exception.count",
        tags: [:route, :method],
        tag_values: &route_tags/1
      ),
      duration("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        tag_values: &view_tags/1
      ),
      # By view only: clients choose event names, so they'd be unbounded.
      duration("phoenix.live_view.handle_event.stop.duration",
        tags: [:view],
        tag_values: &view_tags/1
      ),
      counter("phoenix.live_view.handle_event.exception.count",
        tags: [:view],
        tag_values: &view_tags/1
      )
    ]
  end

  defp repo_metrics do
    [
      duration("firefly.repo.query.total_time",
        tags: [:source],
        tag_values: &%{source: &1[:source] || "none"}
      ),
      # Time waiting for a pooled connection, when one was needed (see
      # attach_queue_time/0).
      duration("firefly.repo.query.queue_time",
        event_name: [:firefly, :repo, :queue],
        measurement: :time
      )
    ]
  end

  defp domain_metrics do
    [
      duration("firefly.notifications.dispatch.stop.duration",
        tags: [:event]
      ),
      counter("firefly.notifications.dispatch.exception.count", tags: [:event]),
      counter("firefly.notifications.created.count", tags: [:kind]),
      counter("firefly.plugins.hook.count", tags: [:plugin, :hook, :result]),
      duration("firefly.plugins.hook.duration",
        tags: [:hook]
      ),
      counter("firefly.plugins.event.stop.count", tags: [:result]),
      counter("firefly.plugins.event.exception.count"),
      last_value("firefly.queue.depth",
        event_name: [:firefly, :queue, :depth],
        measurement: :depth,
        tags: [:queue]
      ),
      duration("firefly.webhooks.delivery.stop.duration",
        tags: [:type, :result]
      ),
      counter("firefly.webhooks.delivery.exception.count", tags: [:type]),
      duration("firefly.scheduler.job.stop.duration",
        tags: [:job]
      ),
      counter("firefly.scheduler.job.exception.count", tags: [:job]),
      counter("firefly.cluster.node.count", tags: [:event]),
      last_value("firefly.cluster.nodes.connected",
        event_name: [:firefly, :cluster, :node],
        measurement: :connected
      )
    ]
  end

  defmodule Buckets do
    @moduledoc false
    # Histogram bounds for durations in microseconds, 0.5ms to 10s: few
    # enough to keep each series small (Peep's default has ~60).
    @bounds [
      500,
      1_000,
      2_500,
      5_000,
      10_000,
      25_000,
      50_000,
      100_000,
      250_000,
      500_000,
      1_000_000,
      2_500_000,
      5_000_000,
      10_000_000
    ]

    use Peep.Buckets.Custom, buckets: @bounds

    def bounds, do: @bounds
  end

  # Durations in microseconds (Peep keeps integers: milliseconds would
  # round most queries to 0), named so: `name` plus `.microseconds`. Peep
  # and OtelMetricExporter (`:buckets`) bucket them alike.
  defp duration(name, opts) do
    name
    |> distribution(
      [
        unit: {:native, :microsecond},
        reporter_options: [peep_bucket_calculator: Buckets, buckets: Buckets.bounds()]
      ] ++ opts
    )
    |> Map.update!(:name, &(&1 ++ [:microseconds]))
  end

  # The route's pattern (`/t/:id`), never the path; unmatched requests
  # have none.
  defp route_tags(%{conn: conn} = metadata) do
    %{route: metadata[:route] || "unmatched", method: conn.method, status: conn.status}
  end

  defp view_tags(%{socket: socket}), do: %{view: inspect(socket.view)}
end
