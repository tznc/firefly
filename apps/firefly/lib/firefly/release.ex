defmodule Firefly.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :firefly

  @doc """
  Runs the control migrations on the host database's `control` schema
  first (see `Firefly.Control.Migrator`), then the forum migrations.
  """
  def migrate do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Firefly.Control.Repo, fn _repo ->
        Firefly.Control.migrate()
      end)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Re-encrypts every secret not yet under the current vault key
  (`bin/firefly eval Firefly.Release.rotate_vault`; see `Firefly.Vault`).
  """
  def rotate_vault do
    load_app()

    {:ok, counts, _} =
      Ecto.Migrator.with_repo(Firefly.Repo, fn _repo ->
        {:ok, _vault} = Firefly.Vault.start_link()
        Firefly.Vault.rotate()
      end)

    counts
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
