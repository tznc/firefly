defmodule Firefly.Telemetry do
  @moduledoc """
  The `:telemetry` events the domain emits, for metrics and traces. The
  domain only emits them; the web app decides what to report and where
  (see `FireflyWeb.Telemetry`).

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
  | `[:firefly, :queue, :depth]` | `depth` | `queue` (`plugin_events`, `webhooks`); from `measure_queues/0` |
  """

  @doc """
  Runs `fun` inside a `:telemetry.span/3` named `event`: `start`, then
  `stop` with the duration (or `exception`, re-raising). `fun` returns
  `{result, stop_metadata}`; the stop event gets `metadata` merged with
  `stop_metadata`. Returns `result`.
  """
  @spec span([atom], map, (-> {result, map})) :: result when result: term
  def span(event, metadata, fun) do
    :telemetry.span(event, metadata, fn ->
      {result, stop_metadata} = fun.()
      {result, Map.merge(metadata, stop_metadata)}
    end)
  end

  @doc "Emits `event` with `measurements` and `metadata`."
  @spec execute([atom], map, map) :: :ok
  def execute(event, measurements, metadata \\ %{}),
    do: :telemetry.execute(event, measurements, metadata)

  @doc """
  Emits `[:firefly, :queue, :depth]` for each background queue: plugin
  events and webhook deliveries waiting. Called periodically by the
  reporter's poller (two counts).
  """
  @spec measure_queues() :: :ok
  def measure_queues do
    execute([:firefly, :queue, :depth], %{depth: Firefly.Plugins.queue_depth()}, %{
      queue: "plugin_events"
    })

    execute([:firefly, :queue, :depth], %{depth: Firefly.Webhooks.pending_count()}, %{
      queue: "webhooks"
    })
  end
end
