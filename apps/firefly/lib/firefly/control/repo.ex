defmodule Firefly.Control.Repo do
  @moduledoc """
  The repo for the host database's `control` schema (see `Firefly.Control`).

  It connects to the same database as tenant 1's forum (`Firefly.Repo`'s
  settings, `FIREFLY_DATABASE_URL`), with a small pool of its own
  (`FIREFLY_CONTROL_POOL_SIZE`, default 2), and is never switched to
  another database: control data lives only on the host. Its schemas set
  `@schema_prefix "control"`; its migrations are in
  `priv/control_repo/migrations` and run through
  `Firefly.Control.Migrator`, which records them in
  `control.schema_migrations`.
  """

  use Ecto.Repo, otp_app: :firefly, adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, config) do
    host = Application.get_env(:firefly, Firefly.Repo, [])
    {:ok, Keyword.merge(host, config)}
  end
end
