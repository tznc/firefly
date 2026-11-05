defmodule FireflyWeb.OpenTelemetry do
  @moduledoc """
  OpenTelemetry: traces, and optionally metrics and logs, exported over
  OTLP. Everything is set with the standard `OTEL_*` environment variables
  (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`,
  `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER`...),
  and nothing is exported unless an endpoint is set (`config/runtime.exs`
  turns each signal on; see `config :firefly_web, FireflyWeb.OpenTelemetry`):

    * `traces`: spans for Bandit's requests, Phoenix's routes and
      LiveViews, Ecto's queries, background jobs (Oban), the AI client's
      HTTP calls and the domain's operations (see `Firefly.Telemetry`).
    * `metrics` (`FIREFLY_OTEL_METRICS=true`): the Prometheus metrics'
      definitions, pushed by `OtelMetricExporter` (see
      `FireflyWeb.Telemetry`), over http/protobuf only, with the traces'
      resource.
    * `logs` (`FIREFLY_OTEL_LOGS=true`, experimental in the Erlang SDK):
      log events, with the trace and span ids of the span they were logged
      in.

  The OpenTelemetry API sets `otel_trace_id` and `otel_span_id` in the
  logger metadata of the process a span is current in, so console logs
  print them too.
  """

  @doc "Whether `signal` (`:traces`, `:metrics` or `:logs`) is exported."
  @spec enabled?(:traces | :metrics | :logs) :: boolean
  def enabled?(signal), do: Keyword.get(config(), signal, false) == true

  @doc """
  Attaches the instrumentation for the signals on. Called once, as the
  web app starts.
  """
  @spec setup() :: :ok
  def setup do
    if enabled?(:traces), do: instrument()
    if enabled?(:logs), do: add_log_handler()
    :ok
  end

  @doc false
  def instrument do
    :ok = OpentelemetryBandit.setup()
    :ok = OpentelemetryPhoenix.setup(adapter: :bandit)
    :ok = OpentelemetryEcto.setup([:firefly, :repo])
    # Job spans, children of the enqueuer's span (see Firefly.Jobs.insert/1).
    OpentelemetryOban.setup(job: [span_relationship: :child])
  end

  @doc """
  The resource the SDK exports traces with (`service.name` from
  `OTEL_SERVICE_NAME` or the release, `OTEL_RESOURCE_ATTRIBUTES`, the
  detected process...), as attributes, for the other exporters.
  """
  @spec resource() :: %{String.t() => term}
  def resource do
    :otel_resource_detector.get_resource()
    |> :otel_resource.attributes()
    |> :otel_attributes.map()
    |> Map.new(fn {key, value} -> {to_string(key), attribute(value)} end)
  end

  # Without a node name, the SDK's service.instance.id is a random 128-bit
  # integer: OTLP's integers are 64-bit.
  defp attribute(value) when is_integer(value) and abs(value) > 0x7FFF_FFFF_FFFF_FFFF,
    do: Integer.to_string(value)

  defp attribute(value), do: value

  defp add_log_handler do
    :ok =
      :logger.add_handler(:otel_logs, :otel_log_handler, %{
        level: :info,
        exporter: {:otel_exporter_logs_otlp, %{}}
      })
  end

  defp config, do: Application.get_env(:firefly_web, __MODULE__, [])
end
