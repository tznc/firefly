defmodule Firefly.Control.Migrator do
  @moduledoc """
  Runs the control migrations (`priv/control_repo/migrations`) on the host
  database's `control` schema, and only there: they always go through
  `Firefly.Control.Repo`, which only ever connects to the host. The forum
  migrations (`priv/repo/migrations`) are the ones tenant databases get;
  this never runs them (its path is explicit, not derived from the repo's
  name, whose last part is `Repo` too).

  The schema is created first, so its version table
  (`control.schema_migrations`) can live in it. `Firefly.Release.migrate/0`
  runs these before the forum migrations, since later steps read the
  tenants from here.
  """

  alias Firefly.Control.Repo

  @prefix "control"

  @doc "Where the control migrations are."
  @spec migrations_path() :: String.t()
  def migrations_path, do: Application.app_dir(:firefly, "priv/control_repo/migrations")

  @doc "Runs every pending control migration. Returns the versions run."
  @spec migrate(keyword) :: [integer]
  def migrate(opts \\ []) do
    Repo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}", [], log: false)
    run(:up, Keyword.merge([all: true], opts))
  end

  @doc "Rolls back control migrations (`step: 1` by default, or `to:`)."
  @spec rollback(keyword) :: [integer]
  def rollback(opts \\ []) do
    run(:down, if(opts[:to], do: opts, else: Keyword.put_new(opts, :step, 1)))
  end

  defp run(direction, opts),
    do: Ecto.Migrator.run(Repo, [migrations_path()], direction, opts ++ [prefix: @prefix])
end
