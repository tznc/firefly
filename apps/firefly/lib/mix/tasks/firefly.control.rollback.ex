defmodule Mix.Tasks.Firefly.Control.Rollback do
  use Boundary, classify_to: Firefly.Control
  @shortdoc "Rolls back control migrations on the host database"

  @moduledoc """
  Rolls back control migrations on the host database's `control` schema
  (see `Firefly.Control.Migrator`): the last one, `--step N`, or
  `--to VERSION`.

      mix firefly.control.rollback [--step N | --to VERSION]
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [step: :integer, to: :integer])
    Mix.Task.run("app.config")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Firefly.Control.Repo, fn _repo ->
        Firefly.Control.Migrator.rollback(opts)
      end)
  end
end
