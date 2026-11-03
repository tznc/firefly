defmodule FireflyImport do
  @moduledoc """
  Importers from other forums and chat platforms. Each one is a source
  (`FireflyImport.Source`) that `FireflyImport.Pipeline` runs, writing what
  it reads through the domain's `Firefly.Import`.

  Run one with `mix firefly.import <source> [options]`, or in a release
  with `bin/firefly eval 'FireflyImport.CLI.main(~w(<source> [options]))'`
  (see `FireflyImport.CLI`). The staff import page shows the runs.
  """

  use Boundary,
    top_level?: true,
    deps: [Firefly, Firefly.Import, Firefly.Rendering],
    exports: [Source, Pipeline, Markdown, SQL, MySQL, CLI]

  @sources %{
    "discourse" => FireflyImport.Sources.Discourse,
    "nodebb" => FireflyImport.Sources.NodeBB,
    "phpbb" => FireflyImport.Sources.PhpBB,
    "vbulletin" => FireflyImport.Sources.VBulletin
  }

  @doc "The importers, by name."
  def sources, do: @sources

  @doc """
  Runs the importer named `source` with `opts` (its options and the
  pipeline's, see `FireflyImport.Pipeline`): `{:ok, run}` or `{:error, run}`,
  or `{:error, :unknown_source}`.
  """
  def run(source, opts) do
    case @sources[to_string(source)] do
      nil -> {:error, :unknown_source}
      module -> FireflyImport.Pipeline.run(module, opts)
    end
  end
end
