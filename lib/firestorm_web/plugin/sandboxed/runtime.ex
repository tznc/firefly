defmodule FirestormWeb.Plugin.Sandboxed.Runtime do
  @moduledoc """
  Runs JavaScript in QuickJS compiled to WebAssembly (`priv/plugins/quickjs.wasm`,
  built by `wasm/quickjs/build.sh`), on wasmtime through Wasmex.

  Every `run/4` gets a fresh store and instance, thrown away afterwards, so
  nothing leaks between calls or plugins. Each call is bounded:

    * memory: the store's linear memory is capped (`:memory`, 32 MB by
      default) and QuickJS's own heap a little below that, so most
      exhaustion surfaces as a catchable JS error, the rest as a failed
      allocation;
    * CPU: wasmtime fuel (`:fuel`); when it runs out the call traps;
    * time: a wall-clock deadline (`:timeout`), as a backstop for time spent
      in host calls;
    * output: the result's size (`:max_output`).

  The module imports nothing that reaches the outside: `firefly.call` and
  `firefly.read` go to the `host` function given per call, and the five WASI
  functions wasi-libc links in are stubs here (writes fail, the clock reads
  the time the call started), so there's no filesystem, network,
  environment or randomness from the host.

  Every failure comes back as `{:error, {kind, message}}` with `kind` one of
  `:timeout`, `:memory`, `:trap`, `:js_error`, `:no_handler`, `:bad_output`
  or `:output_too_large`; the caller never crashes.
  """

  require Logger

  alias Wasmex.{Memory, StoreOrCaller}

  @wasm_path "plugins/quickjs.wasm"
  @module_key {__MODULE__, :module}

  @defaults [
    memory: 32 * 1024 * 1024,
    fuel: 400_000_000,
    timeout: 2_000,
    max_output: 1024 * 1024,
    max_host_response: 1024 * 1024
  ]

  # Status codes from `ff_run` (see wasm/quickjs/firefly_runtime.c).
  @ok 0
  @js_error 1
  @no_handler 2

  # WASI errno for "bad file descriptor": wasi-libc's stdio has no files.
  @ebadf 8

  @type error_kind ::
          :timeout
          | :memory
          | :trap
          | :js_error
          | :no_handler
          | :bad_output
          | :output_too_large
  @type host :: (String.t(), term -> {:ok, term} | {:error, String.t()})

  @doc "The default limits; each can be overridden per call."
  def defaults, do: @defaults

  @doc """
  Runs `hook` exported by the plugin `source` with `input` (JSON-encodable),
  answering its `firefly.call(name, args)`s with `host`. Returns the hook's
  result decoded from JSON.
  """
  @spec run(String.t(), String.t(), term, keyword) ::
          {:ok, term} | {:error, {error_kind, String.t()}}
  def run(source, hook, input, opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    host = Keyword.get(opts, :host, fn name, _args -> {:error, "unknown function #{name}"} end)
    callers = [self() | Process.get(:"$callers", [])]
    # Compiling (once per node) doesn't count against the call's time.
    compiled()

    task =
      Task.Supervisor.async_nolink(FirestormWeb.Plugin.TaskSupervisor, fn ->
        Process.put(:"$callers", callers)
        execute(source, hook, Jason.encode!(input), host, callers, opts)
      end)

    case Task.yield(task, opts[:timeout]) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:trap, "the sandbox crashed: " <> Exception.format_exit(reason)}}

      nil ->
        {:error, {:timeout, "took longer than #{opts[:timeout]}ms"}}
    end
  end

  defp execute(source, hook, input, host, callers, opts) do
    {engine, module} = compiled()
    {:ok, store} = Wasmex.Store.new(%Wasmex.StoreLimits{memory_size: opts[:memory]}, engine)
    :ok = StoreOrCaller.set_fuel(store, opts[:fuel])

    {:ok, pid} =
      Wasmex.start_link(%{
        store: store,
        module: module,
        imports: imports(host, callers, opts)
      })

    try do
      with {:ok, memory} <- Wasmex.memory(pid),
           {:ok, [src]} <- put(pid, store, memory, source),
           {:ok, [name]} <- put(pid, store, memory, hook),
           {:ok, [arg]} <- put(pid, store, memory, input),
           # QuickJS's heap stops a little short of the store's cap, so it
           # throws a catchable error before allocations start failing.
           js_limit = opts[:memory] - 4 * 1024 * 1024,
           {:ok, [status]} <-
             call(pid, "ff_run", [
               src,
               byte_size(source),
               name,
               byte_size(hook),
               arg,
               byte_size(input),
               js_limit
             ]),
           {:ok, output} <- output(pid, store, memory, opts[:max_output]) do
        result(status, output)
      else
        {:error, {_kind, _message}} = error -> error
        {:error, message} when is_binary(message) -> {:error, classify(message)}
      end
    after
      GenServer.stop(pid, :normal, 1_000)
    end
  end

  # NUL-terminated: QuickJS's parsers read up to it.
  defp put(pid, store, memory, binary) do
    case call(pid, "ff_alloc", [byte_size(binary) + 1]) do
      {:ok, [0]} ->
        {:error, {:memory, "out of memory"}}

      {:ok, [ptr]} = ok ->
        :ok = Memory.write_binary(store, memory, ptr, binary <> <<0>>)
        ok

      error ->
        error
    end
  end

  defp call(pid, function, args), do: Wasmex.call_function(pid, function, args, :infinity)

  defp output(pid, store, memory, max) do
    with {:ok, [len]} <- call(pid, "ff_out_len", []),
         {:ok, [ptr]} <- call(pid, "ff_out_ptr", []) do
      if len > max,
        do: {:error, {:output_too_large, "output of #{len} bytes is over the #{max} limit"}},
        else: {:ok, Memory.read_binary(store, memory, ptr, len)}
    end
  end

  defp result(@ok, output) do
    case Jason.decode(output) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, {:bad_output, "the result isn't valid JSON"}}
    end
  end

  defp result(@no_handler, _output), do: {:error, {:no_handler, "the plugin has no such handler"}}

  defp result(@js_error, output) do
    message =
      case Jason.decode(output) do
        {:ok, %{"message" => message} = error} -> Enum.join([message, error["stack"]], "\n")
        _ -> output
      end

    if message =~ "out of memory",
      do: {:error, {:memory, String.trim(message)}},
      else: {:error, {:js_error, String.trim(message)}}
  end

  defp result(_init_error, output), do: {:error, {:memory, output}}

  # Wasmex reports traps as messages.
  defp classify(message) do
    cond do
      message =~ "fuel" -> {:timeout, "used up its CPU budget"}
      message =~ ~r/memory|allocat/i -> {:memory, message}
      true -> {:trap, message}
    end
  end

  defp imports(host, callers, opts) do
    max_response = opts[:max_host_response]
    # The instance's start time is the only clock the plugin sees.
    now = System.os_time(:nanosecond)

    %{
      firefly: %{
        call:
          {:fn, [:i32, :i32, :i32, :i32], [:i32],
           fn %{memory: memory, caller: caller}, name_ptr, name_len, args_ptr, args_len ->
             # Runs in the instance's process: give it the caller's database
             # access (the Ecto sandbox follows `$callers`).
             Process.put(:"$callers", callers)
             name = Memory.read_binary(caller, memory, name_ptr, name_len)
             args = Memory.read_binary(caller, memory, args_ptr, args_len)
             response = host_response(host, name, args, max_response)
             Process.put(:firefly_response, response)
             byte_size(response)
           end},
        read:
          {:fn, [:i32], [],
           fn %{memory: memory, caller: caller}, ptr ->
             :ok =
               Memory.write_binary(caller, memory, ptr, Process.delete(:firefly_response) || "")

             nil
           end}
      },
      wasi_snapshot_preview1: %{
        clock_time_get:
          {:fn, [:i32, :i64, :i32], [:i32],
           fn %{memory: memory, caller: caller}, _clock, _precision, ptr ->
             :ok = Memory.write_binary(caller, memory, ptr, <<now::little-unsigned-64>>)
             0
           end},
        fd_close: {:fn, [:i32], [:i32], fn _context, _fd -> @ebadf end},
        fd_fdstat_get: {:fn, [:i32, :i32], [:i32], fn _context, _fd, _ptr -> @ebadf end},
        fd_seek:
          {:fn, [:i32, :i64, :i32, :i32], [:i32],
           fn _context, _fd, _off, _whence, _ptr -> @ebadf end},
        fd_write:
          {:fn, [:i32, :i32, :i32, :i32], [:i32],
           fn _context, _fd, _iovs, _len, _ptr -> @ebadf end}
      }
    }
  end

  # The plugin gets `{"ok": value}` or `{"error": message}`.
  defp host_response(host, name, args, max) do
    response =
      with {:ok, args} <- Jason.decode(args),
           {:ok, value} <- safe_host_call(host, name, args),
           {:ok, json} <- Jason.encode(%{ok: value}) do
        json
      else
        {:error, message} when is_binary(message) -> Jason.encode!(%{error: message})
        {:error, %{__exception__: true}} -> Jason.encode!(%{error: "invalid JSON"})
      end

    if byte_size(response) > max,
      do: Jason.encode!(%{error: "response too large"}),
      else: response
  end

  defp safe_host_call(host, name, args) do
    host.(name, args)
  rescue
    error ->
      Logger.error("Plugin host function #{name} failed: " <> Exception.message(error))
      {:error, "#{name} failed"}
  end

  @doc """
  The compiled module and its engine, compiled once per node. Raises if the
  `.wasm` doesn't match its committed checksum.
  """
  def compiled do
    case :persistent_term.get(@module_key, nil) do
      nil ->
        bytes = File.read!(Application.app_dir(:firestorm_web, ["priv", @wasm_path]))
        verify!(bytes)
        {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: true})
        {:ok, store} = Wasmex.Store.new(nil, engine)
        {:ok, module} = Wasmex.Module.compile(store, bytes)
        :persistent_term.put(@module_key, {engine, module})
        {engine, module}

      compiled ->
        compiled
    end
  end

  @doc "The runtime's SHA-256, as committed next to it."
  def checksum do
    path = Application.app_dir(:firestorm_web, ["priv", @wasm_path <> ".sha256"])
    path |> File.read!() |> String.split() |> hd()
  end

  defp verify!(bytes) do
    actual = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    if actual != checksum(),
      do: raise("#{@wasm_path} doesn't match its checksum: rebuild it with wasm/quickjs/build.sh")
  end
end
