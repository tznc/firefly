defmodule FirestormWeb.Plugin.GraphTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.Plugin.Graph

  defp node(id, version, requires \\ %{}, opts \\ []) do
    %{
      id: id,
      version: version,
      requires: requires,
      optional: Keyword.get(opts, :optional, %{}),
      priority: Keyword.get(opts, :priority, 100)
    }
  end

  test "dependencies come first; priority breaks ties, then id" do
    nodes = [
      node("app", "1.0.0", %{"lib" => "~> 1.0"}),
      node("lib", "1.1.0", %{"core" => ">= 0.1.0"}),
      node("core", "0.2.0"),
      node("early", "1.0.0", %{}, priority: 10),
      node("zeta", "1.0.0")
    ]

    assert Graph.order(nodes) == ["early", "core", "lib", "app", "zeta"]
    assert Graph.problems(nodes) == %{}
  end

  test "optional dependencies order but aren't required" do
    nodes = [
      node("a", "1.0.0", %{}, optional: %{"b" => "~> 1.0", "gone" => "~> 1.0"}),
      node("b", "1.0.0")
    ]

    assert Graph.order(nodes) == ["b", "a"]
    assert Graph.problems(nodes) == %{}
  end

  test "missing and incompatible dependencies" do
    nodes = [
      node("a", "1.0.0", %{"b" => "~> 2.0", "c" => "~> 1.0"}),
      node("b", "1.5.0"),
      node("d", "1.0.0", %{}, optional: %{"b" => ">= 3.0.0"})
    ]

    assert %{
             "a" => [{:incompatible, "b", "~> 2.0", "1.5.0"}, {:missing, "c", "~> 1.0"}],
             "d" => [{:incompatible, "b", ">= 3.0.0", "1.5.0"}]
           } = Graph.problems(nodes)

    assert Graph.describe({:missing, "c", "~> 1.0"}) ==
             "needs plugin c ~> 1.0, which isn't installed"
  end

  test "cycles are found and named" do
    nodes = [
      node("a", "1.0.0", %{"b" => ">= 0.0.0"}),
      node("b", "1.0.0", %{"c" => ">= 0.0.0"}),
      node("c", "1.0.0", %{"a" => ">= 0.0.0"}),
      node("d", "1.0.0", %{"a" => ">= 0.0.0"})
    ]

    assert Graph.cycles(nodes) == [["a", "b", "c", "a"]]
    problems = Graph.problems(nodes)
    assert problems["b"] == [{:cycle, ["a", "b", "c", "a"]}]
    refute Map.has_key?(problems, "d")
    assert Graph.describe({:cycle, ["a", "b", "a"]}) == "has a dependency cycle: a → b → a"
    # Plugins on or behind the cycle go last, in id order.
    assert Graph.order(nodes) == ["a", "b", "c", "d"]
  end

  test "transitive requirements and dependents" do
    nodes = [
      node("app", "1.0.0", %{"lib" => "~> 1.0"}),
      node("lib", "1.0.0", %{"core" => "~> 1.0"}),
      node("core", "1.0.0"),
      node("extra", "1.0.0", %{}, optional: %{"core" => "~> 1.0"})
    ]

    assert Graph.requirements_of(nodes, "app") == ["lib", "core"]
    assert Graph.dependents_of(nodes, "core") == ["lib", "app"]
  end
end
