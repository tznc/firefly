defmodule FirestormWeb.Plugins.Health do
  @moduledoc """
  How plugins are doing: per-plugin call statistics, the error log, and the
  circuit breaker.

  Statistics (calls, failures, time) are counted in ETS on each node since
  it started; the error log is in the database (the latest
  200 entries per plugin are kept). A failure is any `{kind, message}`
  error from `FirestormWeb.Plugin.Runner`; errors a plugin returns on
  purpose aren't.

  The circuit breaker counts each plugin's failures in a row (on this node);
  at the threshold (`config :firestorm_web, FirestormWeb.Plugins,
  breaker_threshold:`, 5 by default) it turns the plugin off with
  `FirestormWeb.Plugins.trip/2`, which tells staff. Any success resets the
  count.
  """

  import Ecto.Query

  alias FirestormWeb.{Plugins, Repo}
  alias FirestormWeb.Plugins.PluginError

  @table __MODULE__
  @kept_errors 200

  @doc false
  def create_table,
    do: :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

  @doc "Counts a call's result and time (microseconds) for `plugin`."
  def record(plugin, hook, result, elapsed) do
    failed = match?({:error, {kind, _}} when is_atom(kind), result)
    count(plugin.id, failed, elapsed)

    case result do
      {:error, {kind, message}} when is_atom(kind) ->
        log_error(plugin.id, hook, kind, message)
        breaker(plugin, kind, message)

      _ ->
        :ets.insert(@table, {{:streak, plugin.id}, 0})
    end

    :ok
  end

  defp count(id, failed, elapsed) do
    :ets.update_counter(
      @table,
      {:stats, id},
      [{2, 1}, {3, if(failed, do: 1, else: 0)}, {4, elapsed}],
      {{:stats, id}, 0, 0, 0}
    )
  end

  defp breaker(plugin, kind, message) do
    streak = :ets.update_counter(@table, {:streak, plugin.id}, 1, {{:streak, plugin.id}, 0})

    if streak >= threshold() do
      :ets.insert(@table, {{:streak, plugin.id}, 0})

      Plugins.trip(
        plugin.id,
        "#{streak} failures in a row; the last: #{kind}: #{first_line(message)}"
      )
    end
  end

  defp threshold,
    do: Application.get_env(:firestorm_web, Plugins, [])[:breaker_threshold] || 5

  defp first_line(message), do: message |> String.split("\n") |> hd() |> String.slice(0, 200)

  @doc "Adds an entry to `plugin_id`'s error log, dropping the oldest beyond the limit."
  def log_error(plugin_id, hook, kind, message) do
    entry =
      Repo.insert!(%PluginError{
        plugin_id: plugin_id,
        hook: hook,
        kind: to_string(kind),
        message: String.slice(message, 0, 4_000)
      })

    # Pruned now and then rather than on every insert.
    if rem(entry.id, 20) == 0 do
      PluginError
      |> where([e], e.plugin_id == ^plugin_id)
      |> where(
        [e],
        e.id not in subquery(
          PluginError
          |> where([e], e.plugin_id == ^plugin_id)
          |> order_by(desc: :id)
          |> limit(@kept_errors)
          |> select([e], e.id)
        )
      )
      |> Repo.delete_all()
    end

    :ok
  end

  @doc "The latest entries in `plugin_id`'s error log, newest first."
  def errors(plugin_id, limit \\ 50) do
    PluginError
    |> where([e], e.plugin_id == ^plugin_id)
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Clears `plugin_id`'s error log and statistics."
  def clear(plugin_id) do
    Repo.delete_all(where(PluginError, [e], e.plugin_id == ^plugin_id))
    :ets.delete(@table, {:stats, plugin_id})
    reset(plugin_id)
  end

  @doc "Starts `plugin_id`'s circuit breaker count afresh (e.g. when staff enable it)."
  def reset(plugin_id) do
    :ets.delete(@table, {:streak, plugin_id})
    :ok
  end

  @doc "`plugin_id`'s statistics on this node: calls, failures and average time (ms)."
  def stats(plugin_id) do
    case :ets.lookup(@table, {:stats, plugin_id}) do
      [{_key, calls, failures, total}] when calls > 0 ->
        %{calls: calls, failures: failures, average_ms: Float.round(total / calls / 1000, 1)}

      _ ->
        %{calls: 0, failures: 0, average_ms: 0.0}
    end
  end
end
