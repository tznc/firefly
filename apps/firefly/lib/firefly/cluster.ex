defmodule Firefly.Cluster do
  @moduledoc """
  The Cluster context: connects a deployment's nodes into one Erlang
  cluster, so `Firefly.PubSub` broadcasts (cache invalidation, live
  updates, presence) reach every node.

  Nodes find each other through Postgres (libcluster's Postgres strategy,
  `LibclusterPostgres.Strategy`): each node `LISTEN`s on a channel and
  `NOTIFY`s its node name there every heartbeat; the others connect to
  it. No DNS or orchestrator API is involved, only the database the nodes
  already share. Its connection settings are the repo's.

  Off unless configured (`config :firefly, Firefly.Cluster`, from the
  environment in `config/runtime.exs`):

    * `strategy`: `:postgres` (`FIREFLY_CLUSTER=postgres`) or `nil`.
    * `channel`: the Postgres channel (`firefly_cluster`, plus
      `_<FIREFLY_CLUSTER_NAME>`), so deployments sharing a database
      server don't join each other.
    * `heartbeat_interval`: how often a node announces itself, in ms
      (`FIREFLY_CLUSTER_HEARTBEAT_MS`, default 5 seconds).

  Rate limits stay per node (see `Firefly.RateLimit`).
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  # The repo settings the strategy passes on to its Postgres connections.
  @postgrex_keys [
    :hostname,
    :port,
    :username,
    :password,
    :database,
    :ssl,
    :ssl_opts,
    :socket,
    :socket_dir,
    :socket_options,
    :parameters
  ]

  @doc "Whether clustering is on."
  @spec enabled?() :: boolean
  def enabled?, do: config()[:strategy] == :postgres

  @doc """
  The processes clustering needs, for the domain's supervision tree: none
  when it's off.
  """
  @spec child_specs() :: [module]
  def child_specs,
    do: if(enabled?(), do: [__MODULE__.Monitor, __MODULE__.Discovery], else: [])

  @doc """
  libcluster's topologies: the Postgres strategy, connecting with
  `repo_config`'s settings (the repo's by default).
  """
  @spec topologies(keyword) :: keyword
  def topologies(repo_config \\ Firefly.Repo.config()) do
    config = config()

    [
      firefly: [
        strategy: LibclusterPostgres.Strategy,
        config:
          Keyword.take(repo_config, @postgrex_keys) ++
            [
              channel_name: config[:channel] || "firefly_cluster",
              heartbeat_interval: config[:heartbeat_interval] || 5_000
            ]
      ]
    ]
  end

  @doc "Whether clustering is on, and how many other nodes this one is connected to."
  @spec status() :: %{enabled: boolean, nodes: non_neg_integer}
  def status, do: %{enabled: enabled?(), nodes: length(Node.list())}

  defp config, do: Application.get_env(:firefly, __MODULE__, [])
end
