defmodule FireflyWeb.OpenTelemetry do
  @moduledoc """
  OpenTelemetry: traces, and (experimental) metrics and logs, exported over
  OTLP. Everything is set with the standard `OTEL_*` environment variables
  (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`,
  `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER`...,
  read by the SDK itself), and nothing is exported unless an endpoint is
  set (`config/runtime.exs` turns each signal on; see
  `config :firefly_web, FireflyWeb.OpenTelemetry`):

    * `traces`: spans for Bandit's requests, Phoenix's routes and
      LiveViews, Ecto's queries, the AI client's HTTP calls and the
      domain's operations (see `Firefly.Telemetry`).
    * `metrics` (`FIREFLY_OTEL_METRICS=true`, experimental): the
      Prometheus metrics (see `FireflyWeb.OpenTelemetry.Metrics`).
    * `logs` (`FIREFLY_OTEL_LOGS=true`, experimental): log events, with
      the trace and span ids of the span they were logged in.

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
  end

  defp add_log_handler do
    :ok =
      :logger.add_handler(:otel_logs, :otel_log_handler, %{
        level: :info,
        exporter: {:otel_exporter_logs_otlp, %{}}
      })
  end

  defp config, do: Application.get_env(:firefly_web, __MODULE__, [])
end
