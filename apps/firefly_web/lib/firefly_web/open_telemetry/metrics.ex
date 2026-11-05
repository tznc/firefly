defmodule FireflyWeb.OpenTelemetry.Metrics do
  @moduledoc """
  Reports `FireflyWeb.Telemetry.metrics/0` through OpenTelemetry's metrics
  API, so the OTLP exporter sends what Prometheus scrapes: counters and
  sums become counters, distributions histograms (with the same bucket
  bounds) and last values observable gauges, tags their attributes.

  Experimental: OpenTelemetry metrics are still `opentelemetry_experimental`
  in the Erlang SDK (see `FireflyWeb.OpenTelemetry`), so this runs only
  with `FIREFLY_OTEL_METRICS`.
  """
  use GenServer

  alias Telemetry.Metrics.{Counter, Distribution, LastValue, Sum}

  @table __MODULE__.LastValues

  def start_link(metrics), do: GenServer.start_link(__MODULE__, metrics, name: __MODULE__)

  @impl true
  def init(metrics) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    meter =
      :opentelemetry_experimental.get_meter(
        :opentelemetry.instrumentation_scope("firefly", version(), "")
      )

    metrics = Enum.map(metrics, &{&1, instrument(meter, &1)})

    handlers =
      for {event, metrics} <- Enum.group_by(metrics, &elem(&1, 0).event_name) do
        id = {__MODULE__, event}
        :telemetry.attach(id, event, &__MODULE__.handle_event/4, {meter, metrics})
        id
      end

    {:ok, handlers}
  end

  @impl true
  def terminate(_reason, handlers), do: Enum.each(handlers, &:telemetry.detach/1)

  defp version, do: to_string(Application.spec(:firefly_web, :vsn))

  # Sobelow: metric names come from FireflyWeb.Telemetry's fixed definitions.
  # sobelow_skip ["DOS.StringToAtom"]
  defp instrument(meter, metric) do
    name = metric.name |> Enum.join(".") |> String.to_atom()
    opts = %{description: metric.description, unit: unit(metric.unit)}

    case metric do
      %Counter{} ->
        :otel_counter.create(meter, name, opts)

      %Sum{} ->
        :otel_counter.create(meter, name, opts)

      %Distribution{} ->
        bounds =
          case metric.reporter_options[:peep_bucket_calculator] do
            nil -> %{}
            buckets -> %{advisory_params: %{explicit_bucket_boundaries: bounds(buckets, metric)}}
          end

        :otel_histogram.create(meter, name, Map.merge(opts, bounds))

      %LastValue{} ->
        :otel_meter.create_observable_gauge(meter, name, &observations/1, name, opts)
    end

    name
  end

  # The bucket module's upper bounds (the last bucket is +Inf).
  defp bounds(buckets, metric) do
    config = buckets.config(metric)

    for index <- 0..(buckets.number_of_buckets(config) - 1) do
      {bound, _rest} = Float.parse(buckets.upper_bound(index, config))
      bound
    end
  end

  defp unit(:unit), do: nil
  defp unit(unit) when is_atom(unit), do: unit
  defp unit(_unit), do: nil

  @doc false
  def handle_event(_event, measurements, metadata, {meter, metrics}) do
    for {metric, name} <- metrics, keep?(metric, metadata) do
      record(metric, meter, name, measurements, metadata)
    end

    :ok
  end

  defp record(%Counter{} = metric, meter, name, _measurements, metadata),
    do: :otel_counter.add(:otel_ctx.get_current(), meter, name, 1, attributes(metric, metadata))

  defp record(metric, meter, name, measurements, metadata) do
    case measurement(metric, measurements, metadata) do
      value when is_number(value) -> observe(metric, meter, name, value, metadata)
      _missing -> :ok
    end
  end

  defp observe(%Sum{} = metric, meter, name, value, metadata),
    do:
      :otel_counter.add(:otel_ctx.get_current(), meter, name, value, attributes(metric, metadata))

  defp observe(%Distribution{} = metric, meter, name, value, metadata),
    do:
      :otel_histogram.record(
        :otel_ctx.get_current(),
        meter,
        name,
        value,
        attributes(metric, metadata)
      )

  defp observe(%LastValue{} = metric, _meter, name, value, metadata),
    do: :ets.insert(@table, {{name, attributes(metric, metadata)}, value})

  # The gauge's callback: every attribute set's last value.
  defp observations(name) do
    for {{^name, attributes}, value} <- :ets.tab2list(@table), do: {value, attributes}
  end

  defp measurement(%{measurement: fun}, measurements, metadata) when is_function(fun, 2),
    do: fun.(measurements, metadata)

  defp measurement(%{measurement: fun}, measurements, _metadata) when is_function(fun, 1),
    do: fun.(measurements)

  defp measurement(%{measurement: key}, measurements, _metadata), do: measurements[key]

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata), do: keep.(metadata)

  defp attributes(%{tags: tags, tag_values: tag_values}, metadata) do
    metadata
    |> tag_values.()
    |> Map.take(tags)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), attribute(value)} end)
  end

  defp attribute(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp attribute(value) when is_atom(value), do: Atom.to_string(value)
  defp attribute(value), do: inspect(value)
end
