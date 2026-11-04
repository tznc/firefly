defmodule Firefly.Health do
  @moduledoc """
  The Health context: what a readiness probe asks the domain (see the web
  app's `GET /ready`).

  `readiness/0` runs the checks: the database answers `SELECT 1` within a
  short timeout (`config :firefly, Firefly.Health, db_timeout:`, default
  2 seconds) and no migration of the running code is pending. Read-only
  mode, the plugin sandbox and the cluster (how many other nodes this one
  is connected to, see `Firefly.Cluster`) are reported alongside, but
  never make the node unready: a read-only forum still serves pages, core
  plugins run without the sandbox, and a lone node still serves its
  clients.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  alias Firefly.{Backups, Cluster, Repo, Upgrades}
  alias Firefly.Plugin.Sandbox

  @typedoc "A check's outcome: `ok` and, when it isn't, why."
  @type check :: %{required(:ok) => boolean, optional(atom) => term}

  @doc """
  The readiness checks: `%{database: check, migrations: check, read_only:
  check, plugin_sandbox: check, cluster: check}`. Only `database` and
  `migrations` can be `ok: false`.
  """
  @spec readiness() :: %{atom => check}
  def readiness do
    database = database()

    %{
      database: database,
      # Without a database, the migrations can't be read either.
      migrations: if(database.ok, do: migrations(), else: %{ok: false, error: "database down"}),
      read_only: %{ok: true, enabled: Backups.read_only?()},
      plugin_sandbox: %{ok: true, available: Sandbox.implementation() != nil},
      cluster: Map.put(Cluster.status(), :ok, true)
    }
  end

  @doc "Whether every check in `checks` (from `readiness/0`) passed."
  @spec ready?(%{atom => check}) :: boolean
  def ready?(checks), do: Enum.all?(checks, fn {_name, check} -> check.ok end)

  defp database do
    timeout = Application.get_env(:firefly, __MODULE__, [])[:db_timeout] || 2_000

    # A task bounds the pool checkout as well as the query; it runs on the
    # caller's connection in tests (the sandbox follows `$callers`).
    task =
      Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
        Repo.query("SELECT 1", [], timeout: timeout)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, _result}} -> %{ok: true}
      {:ok, {:error, error}} -> %{ok: false, error: Exception.message(error)}
      {:exit, reason} -> %{ok: false, error: Exception.format_exit(reason)}
      nil -> %{ok: false, error: "timed out after #{timeout}ms"}
    end
  end

  defp migrations do
    case Upgrades.pending_migrations() do
      [] -> %{ok: true}
      pending -> %{ok: false, pending: Enum.map(pending, fn {version, _name} -> version end)}
    end
  rescue
    error -> %{ok: false, error: Exception.message(error)}
  end
end
