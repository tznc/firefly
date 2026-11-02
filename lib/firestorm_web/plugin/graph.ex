defmodule FirestormWeb.Plugin.Graph do
  @moduledoc """
  The plugin dependency graph: a DAG whose edges are manifests'
  `dependencies` (required) and `optional_dependencies` (used if installed),
  each with a `Version` requirement.

  Nodes are `%{id, version, requires, optional, priority}` maps (see
  `node/1`). `problems/1` says what's wrong with each node; `order/1` sorts
  them so that every plugin comes after what it depends on, lower `priority`
  first among plugins free to go, then by id, so the order is stable.
  """

  alias FirestormWeb.Plugin.Manifest

  @type graph_node :: %{
          id: String.t(),
          version: String.t(),
          requires: %{String.t() => String.t()},
          optional: %{String.t() => String.t()},
          priority: integer
        }

  @type problem ::
          {:missing, String.t(), String.t()}
          | {:incompatible, String.t(), String.t(), String.t()}
          | {:cycle, [String.t()]}

  @doc "A graph node for a manifest."
  @spec node(Manifest.t()) :: graph_node
  def node(%Manifest{} = manifest) do
    %{
      id: manifest.id,
      version: manifest.version,
      requires: manifest.dependencies,
      optional: manifest.optional_dependencies,
      priority: manifest.priority
    }
  end

  @doc """
  What's wrong with each node, by id (nodes without problems are left out):
  a required dependency that's missing, a dependency (required or optional)
  whose version doesn't meet the requirement, or a cycle the node is on.
  """
  @spec problems([graph_node]) :: %{String.t() => [problem]}
  def problems(nodes) do
    by_id = Map.new(nodes, &{&1.id, &1})

    dependency_problems =
      for node <- nodes,
          problems = dependency_problems(node, by_id),
          problems != [],
          into: %{},
          do: {node.id, problems}

    Enum.reduce(cycles(nodes), dependency_problems, fn cycle, acc ->
      Enum.reduce(Enum.uniq(cycle), acc, fn id, acc ->
        Map.update(acc, id, [{:cycle, cycle}], &(&1 ++ [{:cycle, cycle}]))
      end)
    end)
  end

  defp dependency_problems(node, by_id) do
    required =
      for {dep, requirement} <- Enum.sort(node.requires),
          problem = check(dep, requirement, by_id[dep], false),
          do: problem

    optional =
      for {dep, requirement} <- Enum.sort(node.optional),
          problem = check(dep, requirement, by_id[dep], true),
          do: problem

    required ++ optional
  end

  defp check(dep, requirement, nil, false), do: {:missing, dep, requirement}
  defp check(_dep, _requirement, nil, true), do: nil

  defp check(dep, requirement, %{version: version}, _optional) do
    if Version.match?(version, requirement),
      do: nil,
      else: {:incompatible, dep, requirement, version}
  end

  @doc """
  The ids of `nodes` in dependency order. Plugins on a cycle come last, in
  id order (`problems/1` reports the cycle).
  """
  @spec order([graph_node]) :: [String.t()]
  def order(nodes) do
    ids = MapSet.new(nodes, & &1.id)
    by_id = Map.new(nodes, &{&1.id, &1})
    deps = Map.new(nodes, &{&1.id, MapSet.intersection(edges(&1), ids)})
    sort(by_id, deps, [])
  end

  defp sort(_by_id, deps, sorted) when map_size(deps) == 0, do: Enum.reverse(sorted)

  defp sort(by_id, deps, sorted) do
    ready = for {id, pending} <- deps, MapSet.size(pending) == 0, do: id

    case Enum.sort_by(ready, &{by_id[&1].priority, &1}) do
      [] ->
        # The rest are on or behind a cycle.
        Enum.reverse(sorted) ++ Enum.sort(Map.keys(deps))

      [next | _] ->
        deps =
          deps
          |> Map.delete(next)
          |> Map.new(fn {id, pending} -> {id, MapSet.delete(pending, next)} end)

        sort(by_id, deps, [next | sorted])
    end
  end

  defp edges(node), do: MapSet.new(Map.keys(node.requires) ++ Map.keys(node.optional))

  @doc """
  The cycles among `nodes`, each as the ids along it, starting and ending
  with the same id (`["a", "b", "a"]`).
  """
  @spec cycles([graph_node]) :: [[String.t()]]
  def cycles(nodes) do
    by_id = Map.new(nodes, &{&1.id, &1})

    {cycles, _done} =
      Enum.reduce(Enum.sort(Map.keys(by_id)), {[], MapSet.new()}, fn id, {cycles, done} ->
        visit(id, [], by_id, cycles, done)
      end)

    cycles
    |> Enum.map(&rotate/1)
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp visit(id, path, by_id, cycles, done) do
    cond do
      id in path ->
        cycle = Enum.reverse([id | Enum.take_while(path, &(&1 != id))]) ++ [id]
        {[cycle | cycles], done}

      MapSet.member?(done, id) or not Map.has_key?(by_id, id) ->
        {cycles, done}

      true ->
        {cycles, done} =
          by_id[id]
          |> edges()
          |> Enum.sort()
          |> Enum.reduce({cycles, done}, fn dep, {cycles, done} ->
            visit(dep, [id | path], by_id, cycles, done)
          end)

        {cycles, MapSet.put(done, id)}
    end
  end

  # The same cycle found from different starts reads the same: from its
  # smallest id.
  defp rotate([_ | _] = cycle) do
    ring = Enum.drop(cycle, -1)
    start = Enum.find_index(ring, &(&1 == Enum.min(ring)))
    {before, rest} = Enum.split(ring, start)
    rest ++ before ++ [Enum.min(ring)]
  end

  @doc """
  The ids that `id` needs, directly or not (required dependencies only),
  nearest first.
  """
  def requirements_of(nodes, id) do
    by_id = Map.new(nodes, &{&1.id, &1})
    closure(id, fn node_id -> Map.keys(Map.get(by_id, node_id, %{requires: %{}}).requires) end)
  end

  @doc "The ids that need `id`, directly or not (required dependencies only), nearest first."
  def dependents_of(nodes, id) do
    closure(id, fn node_id ->
      for node <- nodes, Map.has_key?(node.requires, node_id), do: node.id
    end)
  end

  defp closure(id, next) do
    {found, _seen} = walk(Enum.sort(next.(id)), next, [], MapSet.new([id]))
    Enum.reverse(found)
  end

  defp walk([], _next, found, seen), do: {found, seen}

  defp walk(queue, next, found, seen) do
    {found, seen, more} =
      Enum.reduce(queue, {found, seen, []}, fn id, {found, seen, more} ->
        if MapSet.member?(seen, id),
          do: {found, seen, more},
          else: {[id | found], MapSet.put(seen, id), more ++ Enum.sort(next.(id))}
      end)

    walk(more, next, found, seen)
  end

  @doc "A problem as a sentence for staff."
  def describe({:missing, dep, requirement}),
    do: "needs plugin #{dep} #{requirement}, which isn't installed"

  def describe({:incompatible, dep, requirement, version}),
    do: "needs plugin #{dep} #{requirement}, but #{version} is installed"

  def describe({:cycle, cycle}), do: "has a dependency cycle: #{Enum.join(cycle, " → ")}"
end
