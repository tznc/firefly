defmodule FirestormWeb.Plugin.Runner do
  @moduledoc """
  Calls a plugin's hook, the same way for core and sandboxed plugins: in its
  own process under a time limit, so a crash, a hang or a slow plugin never
  takes the caller down or holds it past the limit.

  The result is `{:ok, value}`, `{:error, message}` for a failure the plugin
  meant (e.g. an export refusing bad arguments), `{:error, :not_implemented}`
  when the plugin doesn't implement the hook, or `{:error, {kind, message}}`
  when it failed: `:timeout`, `:memory`, `:trap`, `:js_error`, `:no_handler`,
  `:bad_output`, `:output_too_large` (see
  `FirestormWeb.Plugin.Sandboxed.Runtime`) or `:crash` (a core plugin
  raised or exited). Failures go to the plugin's error log and statistics
  and count towards its circuit breaker (see `FirestormWeb.Plugins.Health`).
  """

  alias FirestormWeb.Plugin
  alias FirestormWeb.Plugins.Health

  @default_timeout 2_000

  @doc "The time limit when a call doesn't give one, in milliseconds."
  def default_timeout,
    do: Application.get_env(:firestorm_web, __MODULE__, [])[:timeout] || @default_timeout

  @doc """
  Calls `hook` of `plugin` with `args` (the callback's arguments after the
  plugin). Options: `:timeout` in milliseconds.
  """
  @spec invoke(Plugin.t(), String.t(), list, keyword) ::
          {:ok, term} | {:error, String.t() | :not_implemented | Plugin.failure()}
  def invoke(%Plugin{} = plugin, hook, args, opts \\ []) do
    case Plugin.hooks()[hook] do
      {name, arity} when length(args) + 1 == arity ->
        if Plugin.implements?(plugin, hook),
          do: run(plugin, hook, name, args, Keyword.get(opts, :timeout, default_timeout())),
          else: {:error, :not_implemented}

      _ ->
        raise ArgumentError, "unknown hook #{hook}/#{length(args) + 1}"
    end
  end

  defp run(plugin, hook, name, args, timeout) do
    started = System.monotonic_time(:microsecond)

    task =
      Task.Supervisor.async_nolink(FirestormWeb.Plugin.TaskSupervisor, fn ->
        Process.put(:firefly_plugin_timeout, timeout)
        apply(plugin.module, name, [plugin | args])
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} -> normalize(value)
        {:exit, reason} -> {:error, {:crash, Exception.format_exit(reason)}}
        nil -> {:error, {:timeout, "took longer than #{timeout}ms"}}
      end

    Health.record(plugin, hook, result, System.monotonic_time(:microsecond) - started)
    result
  end

  defp normalize(:ok), do: {:ok, nil}
  defp normalize({:ok, _value} = ok), do: ok
  defp normalize({:error, message} = error) when is_binary(message), do: error

  defp normalize({:error, {kind, message}} = error) when is_atom(kind) and is_binary(message),
    do: error

  defp normalize(other), do: {:error, {:bad_output, "unexpected return value #{inspect(other)}"}}
end
