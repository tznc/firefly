defmodule Mix.Tasks.Firefly.Import do
  use Boundary, classify_to: FireflyImport
  @shortdoc "Imports a forum or chat platform's content"

  @moduledoc """
  Imports another forum's or chat platform's content:

      mix firefly.import discourse --source-url postgres://localhost/discourse --uploads-dir uploads/default

  Run it again to resume a stopped import or pick up what's new. See
  `FireflyImport.CLI` for the options every source takes, and each source
  (`FireflyImport.Sources.*`) for its own. In a release:

      bin/firefly eval 'FireflyImport.CLI.main(~w(discourse --source-url postgres://...))'
  """

  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.config")

    case FireflyImport.CLI.main(argv) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
