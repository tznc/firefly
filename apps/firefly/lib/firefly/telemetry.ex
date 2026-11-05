defmodule Firefly.Telemetry do
  @moduledoc """
  The `:telemetry` events the domain emits, for metrics and traces. The
  domain only emits them; the web app decides what to report and where
  (see `FireflyWeb.Telemetry` and `FireflyWeb.OpenTelemetry`).

  Every `span/3` is also an OpenTelemetry span named after its event
  (`firefly.webhooks.delivery`), with the metadata as attributes, through
  the OpenTelemetry API alone: a no-op until the web app starts the SDK.
  Background work started with `bind/1` (tasks, the notification
  dispatcher) joins the trace of the process that started it.

  Metadata stays low-cardinality: kinds, names and outcomes, never user
  ids or free text.

  | Event | Measurements | Metadata |
  | --- | --- | --- |
  | `[:firefly, :notifications, :dispatch, :start \\| :stop \\| :exception]` | `duration` | `event` (`post_created`, `message_created`...) |
  | `[:firefly, :notifications, :created]` | `count` | `kind` |
  | `[:firefly, :plugins, :hook]` | `duration` (native), `count` | `plugin`, `hook`, `result` (`ok`, `error`) |
  | `[:firefly, :plugins, :event, :start \\| :stop \\| :exception]` | `duration` | `result` (`delivered`, `failed`, `dropped`) on stop |
  | `[:firefly, :webhooks, :delivery, :start \\| :stop \\| :exception]` | `duration` | `type` (event type), `result` (`success`, `failure`) on stop |
  | `[:firefly, :scheduler, :job, :start \\| :stop \\| :exception]` | `duration` | `job` |
  | `[:firefly, :discussion, :create_post, :start \\| :stop \\| :exception]` | `duration` | `result` (`ok`, `error`) on stop |
  | `[:firefly, :plugins, :run_hook, :start \\| :stop \\| :exception]` | `duration` | `plugin`, `hook`; `result` on stop |
  | `[:firefly, :ai, :request, :start \\| :stop \\| :exception]` | `duration` | `adapter`; `result` on stop |
  | `[:firefly, :mailer, :deliver, :start \\| :stop \\| :exception]` | `duration` | `adapter` (`smtp`, `ses`...), `template`; `result` (`sent`, `failed`, `skipped`) on stop |
  | `[:firefly, :queue, :depth]` | `depth` | `queue` (`plugin_events`, `webhooks`); from `measure_queues/0` |
  | `[:firefly, :jobs, :depth]` | `count` | `queue`, `state`: background jobs (see `Firefly.Jobs`); from `measure_queues/0` |
  | `[:firefly, :cluster, :node]` | `count`, `connected` (other nodes now) | `event` (`up`, `down`), `node` |
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Runs `fun` inside a `:telemetry.span/3` named `event`: `start`, then
  `stop` with the duration (or `exception`, re-raising). `fun` returns
  `{result, stop_metadata}`; the stop event gets `metadata` merged with
  `stop_metadata`. Returns `result`.
  """
  @spec span([atom], map, (-> {result, map})) :: result when result: term
  def span(event, metadata, fun) do
    Tracer.with_span Enum.map_join(event, ".", &Atom.to_string/1), %{
      attributes: attributes(metadata)
    } do
      telemetry_span(event, metadata, fun)
    end
  end

  defp telemetry_span(event, metadata, fun) do
    :telemetry.span(event, metadata, fn ->
      {result, stop_metadata} = fun.()
      Tracer.set_attributes(attributes(stop_metadata))
      {result, Map.merge(metadata, stop_metadata)}
    end)
  rescue
    error ->
      Tracer.record_exception(error, __STACKTRACE__)
      Tracer.set_status(OpenTelemetry.status(:error, Exception.message(error)))
      reraise error, __STACKTRACE__
  end

  @doc """
  Wraps `fun` to run in the current trace context wherever it's called:
  for work handed to another process (a task, a GenServer), so its spans
  join the caller's trace.
  """
  @spec bind((-> result)) :: (-> result) when result: term
  def bind(fun) do
    ctx = OpenTelemetry.Ctx.get_current()

    fn ->
      OpenTelemetry.Ctx.attach(ctx)
      fun.()
    end
  end

  @doc "The current trace context, to hand to another process (see `attach/1`)."
  @spec current_context() :: term
  def current_context, do: OpenTelemetry.Ctx.get_current()

  @doc "Makes `ctx` (from `current_context/0`) this process's trace context."
  @spec attach(term) :: term
  def attach(ctx), do: OpenTelemetry.Ctx.attach(ctx)

  # Scalar metadata only, as strings where OpenTelemetry wants them.
  defp attributes(metadata) do
    for {key, value} <- metadata, attribute = attribute(value), into: %{} do
      {"firefly.#{key}", attribute}
    end
  end

  defp attribute(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp attribute(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp attribute(_value), do: nil

  @doc "Emits `event` with `measurements` and `metadata`."
  @spec execute([atom], map, map) :: :ok
  def execute(event, measurements, metadata \\ %{}),
    do: :telemetry.execute(event, measurements, metadata)

  @doc """
  Emits `[:firefly, :queue, :depth]` for each background queue: plugin
  events and webhook deliveries waiting, and background jobs by queue and
  state. Called periodically by the reporter's poller (three counts).
  """
  @spec measure_queues() :: :ok
  def measure_queues do
    execute([:firefly, :queue, :depth], %{depth: Firefly.Plugins.queue_depth()}, %{
      queue: "plugin_events"
    })

    execute([:firefly, :queue, :depth], %{depth: Firefly.Webhooks.pending_count()}, %{
      queue: "webhooks"
    })

    for {{queue, state}, count} <- Firefly.Jobs.counts() do
      execute([:firefly, :jobs, :depth], %{count: count}, %{queue: queue, state: state})
    end

    :ok
  end
end
