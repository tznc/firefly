defmodule Mix.Tasks.Firefly.Control.Migrate do
  use Boundary, classify_to: Firefly.Control
  @shortdoc "Runs the control migrations on the host database"

  @moduledoc """
  Runs the pending control migrations on the host database's `control`
  schema (see `Firefly.Control.Migrator`):

      mix firefly.control.migrate [--quiet]

  `mix ecto.migrate` runs it first, then the forum migrations. In a
  release, `bin/migrate` does both.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [quiet: :boolean])
    Mix.Task.run("app.config")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Firefly.Control.Repo, fn _repo ->
        Firefly.Control.Migrator.migrate(log: !opts[:quiet] && :info)
      end)
  end
end
