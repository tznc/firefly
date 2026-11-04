defmodule Firefly.Cluster.Monitor do
  @moduledoc """
  Logs nodes joining and leaving the cluster and emits
  `[:firefly, :cluster, :node]` for each (see `Firefly.Telemetry`). Hidden
  nodes (remote consoles, `bin/firefly rpc`) aren't counted.
  """
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok = :net_kernel.monitor_nodes(true, [:nodedown_reason, node_type: :visible])
    {:ok, nil}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    connected = report(:up, node)
    Logger.info("Cluster: #{node} joined (#{connected} other nodes connected)")
    {:noreply, state}
  end

  def handle_info({:nodedown, node, info}, state) do
    connected = report(:down, node)

    Logger.warning(
      "Cluster: #{node} left (#{inspect(info[:nodedown_reason])}; #{connected} other nodes connected)"
    )

    {:noreply, state}
  end

  defp report(event, node) do
    connected = length(Node.list())

    Firefly.Telemetry.execute([:firefly, :cluster, :node], %{count: 1, connected: connected}, %{
      event: event,
      node: node
    })

    connected
  end
end
