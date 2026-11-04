defmodule Firefly.BoundariesTest do
  @moduledoc """
  The contexts may only use each other through their public API: the
  context's root module and the modules its `use Boundary` exports.

  The `boundary` compiler enforces that for the web and plugin apps (their
  boundaries declare deps on the contexts), but contexts call each other in
  both directions, which `boundary` only allows with its checks off for
  them. This test checks those calls instead: it reads every module
  reference in the domain's source (aliases expanded) and fails on any
  that reaches into another context.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../lib", __DIR__)

  # The plugin context has two roots: the plugin API (`Firefly.Plugin`) and
  # installed plugins (`Firefly.Plugins`).
  @same_context %{Firefly.Plugin => Firefly.Plugins}

  # The application starts every context's processes: it's the one place
  # allowed to name their internals.
  @composition_root Firefly.Application

  test "contexts only use each other's public API" do
    boundaries = boundaries()

    violations =
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          {from, refs} <- references(path),
          from != @composition_root,
          from_boundary = boundary_of(from, boundaries),
          from_boundary != nil,
          to <- refs,
          # Process names (`Firefly.PubSub`) aren't modules.
          Code.ensure_loaded?(to),
          to_boundary = boundary_of(to, boundaries),
          to_boundary != nil,
          context(to_boundary) != context(from_boundary),
          not public?(to, to_boundary, boundaries) do
        "#{Path.relative_to(path, @lib)}: #{inspect(from)} -> #{inspect(to)}"
      end

    assert Enum.uniq(violations) == [],
           "References to other contexts' internals:\n" <>
             Enum.join(Enum.uniq(violations), "\n")
  end

  test "every context is a boundary" do
    boundaries = boundaries()

    for context <- [
          Firefly.Health,
          Firefly.Packages,
          Firefly.Plugins,
          Firefly.Plugin,
          Firefly.Themes
        ] do
      assert Map.has_key?(boundaries, context), "#{inspect(context)} isn't a boundary"
    end

    assert MapSet.equal?(
             boundaries[Firefly.Packages],
             MapSet.new([Firefly.Packages.Package, Firefly.Packages.Archive])
           )
  end

  # Every compiled boundary of the domain, with its exports (full names).
  defp boundaries do
    {:ok, modules} = :application.get_key(:firefly, :modules)

    for module <- modules,
        [%{opts: opts}] <- [Keyword.get(module.__info__(:attributes), Boundary, [])],
        is_nil(opts[:classify_to]),
        into: %{} do
      {module, MapSet.new(opts[:exports] || [], &Module.concat(module, &1))}
    end
  end

  defp boundary_of(module, boundaries) do
    parts = Module.split(module)

    Enum.find_value(length(parts)..1//-1, fn n ->
      candidate = Module.concat(Enum.take(parts, n))
      if Map.has_key?(boundaries, candidate), do: candidate
    end)
  end

  defp context(boundary), do: Map.get(@same_context, boundary, boundary)

  defp public?(module, boundary, boundaries),
    do: module == boundary or MapSet.member?(boundaries[boundary], module)

  # The file's module and the domain modules it refers to (files hold one
  # module, sometimes with small helpers nested inside it).
  defp references(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    aliases = aliases(ast)

    {_ast, {from, refs}} =
      Macro.prewalk(ast, {nil, MapSet.new()}, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, {nil, refs} ->
          {node, {Module.concat(parts), refs}}

        {:__aliases__, _, [head | rest]} = node, {from, refs} when is_atom(head) ->
          module = Module.concat([Map.get(aliases, head, head) | rest])
          {node, {from, if(domain?(module), do: MapSet.put(refs, module), else: refs)}}

        node, acc ->
          {node, acc}
      end)

    if from, do: [{from, refs}], else: []
  end

  defp domain?(module), do: match?(["Firefly" | _], Module.split(module))

  # Short name => full module, from the file's `alias` directives.
  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn {:__aliases__, _, parts}, acc ->
             Map.put(acc, List.last(parts), Module.concat(base ++ parts))
           end)}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]} = node, acc ->
          {node, Map.put(acc, as, Module.concat(parts))}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), Module.concat(parts))}

        node, acc ->
          {node, acc}
      end)

    aliases
  end
end
