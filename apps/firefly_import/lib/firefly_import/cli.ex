defmodule FireflyImport.CLI do
  @moduledoc """
  The command line: `mix firefly.import <source> [options]`, or in a
  release `bin/firefly eval 'FireflyImport.CLI.main(~w(<source> [options]))'`.

  Options for every source:

    * `--dry-run`: import everything in a transaction that's rolled back,
      without storing files, to see what an import would do
    * `--batch-size N`: records written per transaction (default 500)
    * `--permalink-prefix PATH`: the old site's subfolder (e.g. `forum/`), for
      its permalinks
    * `--source-name NAME`: the name its imported ids are kept under (default:
      the source's; set one per site when importing two sites from the same
      platform)
    * `--embeddings`: also embed the posts for semantic search, afterwards
    * `--skip-after`: skip updating stats, badges and trust levels afterwards

  Run again to resume a stopped import, or to import what's new since.
  """

  @common [
    dry_run: :boolean,
    batch_size: :integer,
    permalink_prefix: :string,
    source_name: :string,
    embeddings: :boolean,
    skip_after: :boolean
  ]

  @doc "Runs the import `argv` asks for, printing its log; returns the exit status."
  def main([source | args]), do: run(FireflyImport.sources()[source], source, args)
  def main([]), do: usage_error("Which source? One of: #{names()}")

  defp run(nil, source, _args),
    do: usage_error("Unknown source #{inspect(source)}. One of: #{names()}")

  defp run(module, _source, args) do
    case OptionParser.parse(args, strict: @common ++ module.switches()) do
      {opts, [], []} ->
        {:ok, _apps} = Application.ensure_all_started(:firefly_import)
        opts = Keyword.put(opts, :report, &IO.puts/1)

        case FireflyImport.Pipeline.run(module, opts) do
          {:ok, _run} -> 0
          {:error, _run} -> 1
        end

      {_opts, _args, invalid} ->
        usage_error("Unknown or invalid options: #{inspect(invalid)}\n\n#{usage(module)}")
    end
  end

  @doc "The usage text for a source."
  def usage(module) do
    "Usage: mix firefly.import #{module.name()} [options]\n\n#{module.usage()}"
  end

  defp names, do: FireflyImport.sources() |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp usage_error(message) do
    IO.puts(:stderr, message)
    2
  end
end
