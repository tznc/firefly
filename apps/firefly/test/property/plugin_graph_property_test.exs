defmodule Firefly.PluginGraphPropertyTest do
  @moduledoc """
  Properties of `Firefly.Plugin.Graph`, against a naive model: cycles are
  found exactly when there are some (and each is a real one), activation
  order respects every dependency when there's no cycle, problems name
  exactly the missing and incompatible dependencies, and the transitive
  closures are right.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Firefly.Generators

  alias Firefly.Plugin.Graph

  @ids ~w(a b c d e f g h)

  # Nodes over a small id space, so edges hit present and absent ids.
  defp graph(opts \\ []) do
    ids = Keyword.get(opts, :ids, @ids)

    bind(list_of(member_of(ids), min_length: 1, max_length: length(ids)), fn present ->
      present = Enum.uniq(present)

      present
      |> Enum.map(fn id ->
        fixed_map(%{
          id: constant(id),
          version: version(),
          requires: map_of(member_of(ids ++ ["zz"]), requirement(), max_length: 3),
          optional: map_of(member_of(ids), requirement(), max_length: 2),
          priority: integer(0..3)
        })
      end)
      |> fixed_list()
    end)
  end

  defp acyclic_graph do
    map(graph(), fn nodes ->
      # Only edges to ids that come earlier: no cycles.
      index = nodes |> Enum.with_index() |> Map.new(fn {node, i} -> {node.id, i} end)

      Enum.map(nodes, fn node ->
        keep = fn deps ->
          Map.filter(deps, fn {dep, _} -> (index[dep] || -1) < index[node.id] end)
        end

        %{node | requires: keep.(node.requires), optional: keep.(node.optional)}
      end)
    end)
  end

  defp edges(nodes) do
    present = MapSet.new(nodes, & &1.id)

    for node <- nodes,
        dep <- Map.keys(node.requires) ++ Map.keys(node.optional),
        MapSet.member?(present, dep),
        uniq: true,
        do: {node.id, dep}
  end

  # Kahn's algorithm: whether the present nodes have a cycle.
  defp cyclic?(nodes) do
    edges = edges(nodes)
    ids = Enum.map(nodes, & &1.id)

    Stream.iterate({ids, edges}, fn {ids, edges} ->
      free = Enum.filter(ids, fn id -> not Enum.any?(edges, &(elem(&1, 0) == id)) end)
      {ids -- free, Enum.reject(edges, fn {_, dep} -> dep in free end)}
    end)
    |> Enum.reduce_while(nil, fn {ids, _edges} = state, previous ->
      cond do
        ids == [] -> {:halt, false}
        state == previous -> {:halt, true}
        true -> {:cont, state}
      end
    end)
  end

  property "order/1 is a permutation of the ids" do
    check all(nodes <- graph(), max_runs: runs(200)) do
      assert Enum.sort(Graph.order(nodes)) == Enum.sort(Enum.map(nodes, & &1.id))
    end
  end

  property "cycles are found exactly when there are some, and each is real" do
    check all(nodes <- graph(), max_runs: runs(300)) do
      cycles = Graph.cycles(nodes)
      assert cycles != [] == cyclic?(nodes)

      edges = MapSet.new(edges(nodes))

      for [first | _] = cycle <- cycles do
        assert List.last(cycle) == first
        for [from, to] <- Enum.chunk_every(cycle, 2, 1, :discard), do: assert({from, to} in edges)
      end
    end
  end

  property "without cycles, everything comes after what it depends on" do
    check all(nodes <- acyclic_graph(), max_runs: runs(300)) do
      assert Graph.cycles(nodes) == []
      position = Graph.order(nodes) |> Enum.with_index() |> Map.new()

      for {id, dep} <- edges(nodes) do
        assert position[dep] < position[id], "#{id} needs #{dep} but comes first"
      end
    end
  end

  property "with cycles, the nodes free of them still come in dependency order first" do
    check all(nodes <- graph(), max_runs: runs(200)) do
      order = Graph.order(nodes)
      position = order |> Enum.with_index() |> Map.new()

      # A node whose dependencies (transitively) are all placed before it
      # in a valid order: it's never behind a node it needs.
      for {id, dep} <- edges(nodes), position[dep] > position[id] do
        assert Enum.any?(Graph.cycles(nodes), &(id in &1)) or
                 Enum.any?(optional_closure(nodes, id), fn d ->
                   Enum.any?(Graph.cycles(nodes), &(d in &1))
                 end),
               "#{id} comes before #{dep} without a cycle in the way"
      end
    end
  end

  property "problems name exactly the missing and incompatible dependencies, and cycles" do
    check all(nodes <- graph(), max_runs: runs(300)) do
      problems = Graph.problems(nodes)
      by_id = Map.new(nodes, &{&1.id, &1})
      cyclic = nodes |> Graph.cycles() |> List.flatten() |> MapSet.new()

      for node <- nodes do
        required =
          for {dep, req} <- Enum.sort(node.requires),
              problem =
                (case by_id[dep] do
                   nil -> {:missing, dep, req}
                   %{version: v} -> if !Version.match?(v, req), do: {:incompatible, dep, req, v}
                 end),
              do: problem

        optional =
          for {dep, req} <- Enum.sort(node.optional),
              %{version: v} <- [by_id[dep]],
              !Version.match?(v, req),
              do: {:incompatible, dep, req, v}

        dependency_problems = Enum.reject(problems[node.id] || [], &match?({:cycle, _}, &1))
        assert Enum.sort(dependency_problems) == Enum.sort(required ++ optional)
        assert Enum.any?(problems[node.id] || [], &match?({:cycle, _}, &1)) == node.id in cyclic
      end
    end
  end

  property "requirements_of/2 and dependents_of/2 are the transitive closures" do
    check all(nodes <- graph(), id <- member_of(@ids), max_runs: runs(200)) do
      required = for node <- nodes, dep <- Map.keys(node.requires), do: {node.id, dep}

      reach = fn from, step ->
        Stream.iterate(MapSet.new([from]), fn seen ->
          MapSet.union(seen, MapSet.new(Enum.flat_map(seen, step)))
        end)
        |> Enum.reduce_while(nil, fn seen, prev ->
          if seen == prev, do: {:halt, seen}, else: {:cont, seen}
        end)
        |> MapSet.delete(from)
      end

      needs = reach.(id, fn x -> for {^x, dep} <- required, do: dep end)
      needed_by = reach.(id, fn x -> for {node, ^x} <- required, do: node end)

      assert MapSet.new(Graph.requirements_of(nodes, id)) == needs
      assert MapSet.new(Graph.dependents_of(nodes, id)) == needed_by
      refute id in Graph.requirements_of(nodes, id)
      assert Graph.requirements_of(nodes, id) == Enum.uniq(Graph.requirements_of(nodes, id))
    end
  end

  property "describe/1 says something for every problem" do
    check all(nodes <- graph(), max_runs: runs(100)) do
      for {_id, problems} <- Graph.problems(nodes), problem <- problems do
        assert is_binary(Graph.describe(problem))
      end
    end
  end

  defp optional_closure(nodes, id) do
    by_id = Map.new(nodes, &{&1.id, &1})

    Stream.iterate(MapSet.new([id]), fn seen ->
      MapSet.union(
        seen,
        MapSet.new(
          for x <- seen,
              node = by_id[x],
              node != nil,
              dep <- Map.keys(node.requires) ++ Map.keys(node.optional),
              do: dep
        )
      )
    end)
    |> Enum.reduce_while(nil, fn seen, prev ->
      if seen == prev, do: {:halt, seen}, else: {:cont, seen}
    end)
    |> MapSet.delete(id)
    |> MapSet.to_list()
  end
end
