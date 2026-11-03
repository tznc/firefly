defmodule Firefly.Backups.Runner do
  @moduledoc """
  Runs one backup or restore at a time on this node (see
  `Firefly.Backups`), in a process of its own, keeping its log and
  broadcasting each line (`{:backup_log, line}`) and the outcome
  (`{:backup_finished, operation, result}`) on `Firefly.Backups.topic/0`,
  so the backups page shows progress live, even when opened midway.

  It also applies read-only mode on this node when any node changes it.
  """
  use GenServer

  require Logger

  @read_only_key {Firefly.Backups, :read_only}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Starts `fun` (given a function to log a line with) as `operation`, unless
  something is running: `:ok` or `{:error, :busy}`.
  """
  def run(operation, fun), do: GenServer.call(__MODULE__, {:run, operation, fun})

  @doc "What's running (`operation` or nil) and its log so far (or the last one's)."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "This node's read-only state: nil, or `%{reason: text, since: datetime}`."
  def read_only, do: :persistent_term.get(@read_only_key, nil)

  @doc false
  def put_read_only(value), do: :persistent_term.put(@read_only_key, value)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Firefly.PubSub, Firefly.Backups.read_only_topic())
    {:ok, %{running: nil, pid: nil, log: []}}
  end

  @impl true
  def handle_call({:run, _operation, _fun}, _from, %{running: running} = state)
      when running != nil,
      do: {:reply, {:error, :busy}, state}

  def handle_call({:run, operation, fun}, _from, state) do
    runner = self()

    {pid, _ref} =
      spawn_monitor(fun_with_log(runner, operation, fun))

    broadcast({:backup_started, operation})
    {:reply, :ok, %{state | running: operation, pid: pid, log: []}}
  end

  def handle_call(:status, _from, state),
    do: {:reply, %{running: state.running, log: Enum.reverse(state.log)}, state}

  defp fun_with_log(runner, operation, fun) do
    fn ->
      log = fn line -> GenServer.cast(runner, {:log, line}) end

      result =
        try do
          fun.(log)
        rescue
          error ->
            Logger.error(
              "#{operation} failed: " <> Exception.format(:error, error, __STACKTRACE__)
            )

            {:error, Exception.message(error)}
        end

      GenServer.cast(runner, {:done, result})
    end
  end

  @impl true
  def handle_cast({:log, line}, state) do
    broadcast({:backup_log, line})
    {:noreply, %{state | log: [line | state.log]}}
  end

  def handle_cast({:done, result}, state) do
    line =
      case result do
        {:error, message} -> "Failed: #{message}"
        _ok -> "Done."
      end

    broadcast({:backup_log, line})
    broadcast({:backup_finished, state.running, result})
    {:noreply, %{state | running: nil, pid: nil, log: [line | state.log]}}
  end

  @impl true
  def handle_info({:read_only, value}, state) do
    put_read_only(value)
    {:noreply, state}
  end

  # Finished normally: `:done` came first. Anything else crashed.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pid: pid} = state)
      when reason != :normal do
    handle_cast({:done, {:error, "crashed: #{inspect(reason)}"}}, state)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp broadcast(message),
    do: Phoenix.PubSub.broadcast(Firefly.PubSub, Firefly.Backups.topic(), message)
end
