defmodule Firefly.Plugins.EventWorker do
  @moduledoc """
  Delivers one event to one plugin's `handle_event` hook (see
  `Firefly.Plugins.Events`), as an Oban job in the `plugins` queue. A
  failed delivery is retried after 30 seconds, 2 minutes, 8 minutes and 32
  minutes; the fifth failure drops it and logs that it gave up. An event for
  a plugin that's inactive when it comes due is dropped.
  """
  use Oban.Worker, queue: :plugins, max_attempts: 5

  alias Firefly.Plugin.Runner
  alias Firefly.Plugins
  alias Firefly.Plugins.Health

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 30 * 4 ** (attempt - 1)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"plugin_id" => id, "event" => event, "payload" => payload}} = job) do
    Firefly.Telemetry.span([:firefly, :plugins, :event], %{}, fn ->
      result = deliver(id, event, payload, job)
      {result, %{result: outcome(result)}}
    end)
  end

  defp deliver(id, event, payload, job) do
    with %{} = plugin <- Plugins.get_active(id),
         {:ok, _} <-
           Runner.invoke(plugin, "handle_event", [%{"event" => event, "data" => payload}]) do
      :ok
    else
      nil ->
        {:cancel, "the plugin is inactive"}

      {:error, reason} ->
        message = describe(reason)

        if job.attempt >= job.max_attempts,
          do:
            Health.log_error(
              id,
              "handle_event",
              :gave_up,
              "Dropped #{event} after #{job.attempt} attempts; the last: #{message}"
            )

        {:error, message}
    end
  end

  defp outcome(:ok), do: "delivered"
  defp outcome({:cancel, _}), do: "dropped"
  defp outcome({:error, _}), do: "failed"

  defp describe({kind, message}), do: "#{kind}: #{message}"
  defp describe(reason), do: inspect(reason)
end
