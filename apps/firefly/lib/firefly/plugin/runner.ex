defmodule Firefly.Plugin.Runner do
  @moduledoc """
  Calls a plugin's hook, the same way for core and sandboxed plugins: in its
  own process under a time limit, so a crash, a hang or a slow plugin never
  takes the caller down or holds it past the limit.

  The result is `{:ok, value}`, `{:error, message}` for a failure the plugin
  meant (e.g. an export refusing bad arguments), `{:error, :not_implemented}`
  when the plugin doesn't implement the hook, or `{:error, {kind, message}}`
  when it failed: `:timeout`, `:memory`, `:trap`, `:js_error`, `:no_handler`,
  `:bad_output`, `:output_too_large` (see
  `FireflyPlugins.Runtime`) or `:crash` (a core plugin
  raised or exited). Failures go to the plugin's error log and statistics
  and count towards its circuit breaker (see `Firefly.Plugins.Health`).

  The call's process knows which hook it runs for (`context/0`), so host
  functions can depend on it (see `Firefly.Plugin.Host`). An export
  called from another plugin's hook (`plugins.call`) runs in its caller's
  context, so a chain of calls is judged by the hook it started from.
  """

  alias Firefly.Plugin
  alias Firefly.Plugins.Health

  @default_timeout 2_000
  @context_key :firefly_plugin_context

  @doc "The time limit when a call doesn't give one, in milliseconds."
  def default_timeout,
    do: Application.get_env(:firefly, __MODULE__, [])[:timeout] || @default_timeout

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

  @doc """
  The hook the current process runs a plugin call for (`"call_export"` for
  an export called from Elixir rather than from a hook), or nil outside one.
  """
  def context, do: Process.get(@context_key)

  @doc "Makes the current process run in `context` (see `context/0`)."
  def put_context(context), do: Process.put(@context_key, context)

  defp run(plugin, hook, name, args, timeout) do
    started = System.monotonic_time(:microsecond)
    context = if hook == "call_export", do: context() || hook, else: hook

    task =
      Task.Supervisor.async_nolink(Firefly.Plugin.TaskSupervisor, fn ->
        put_context(context)
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
