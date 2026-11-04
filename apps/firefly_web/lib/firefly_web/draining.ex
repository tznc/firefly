defmodule FireflyWeb.Draining do
  @moduledoc """
  Marks the node as draining when it shuts down, so `GET /ready` answers
  `503` (see `FireflyWeb.Plugs.Health`) while requests in flight finish.

  It starts after the endpoint, so it stops before it: on shutdown it
  flags the node, then waits `config :firefly_web, FireflyWeb.Draining,
  delay:` milliseconds (`FIREFLY_DRAIN_DELAY_MS`, default 0) before the
  endpoint stops listening, giving load balancers polling `/ready` time to
  take the node out of rotation.
  """
  use GenServer

  @key {__MODULE__, :draining}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    # Shutdown must outlast the delay, or the supervisor kills it early.
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: delay() + 5_000}
  end

  @doc "Whether the node is shutting down."
  @spec draining?() :: boolean
  def draining?, do: :persistent_term.get(@key, false)

  @doc "Flags the node as draining (or not)."
  @spec put_draining(boolean) :: :ok
  def put_draining(draining?), do: :persistent_term.put(@key, draining?)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    put_draining(false)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    put_draining(true)
    Process.sleep(delay())
  end

  defp delay, do: Application.get_env(:firefly_web, __MODULE__, [])[:delay] || 0
end
