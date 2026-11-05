defmodule Firefly.PolicyPropertyTest do
  @moduledoc """
  Properties of access to restricted categories, for random groups,
  members, category trees and restrictions: the one-thread rule
  (`Bodyguard`, as the web and API use it) and the query rules (lists and
  search) always agree, so private threads never leak; search parsing is
  total, and its filters never widen access.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Discussion, Groups}
  alias Firefly.Discussion.{Category, Policy, Search, Thread}

  defp can?(user, action, resource), do: Bodyguard.permit?(Discussion, action, user, resource)

  # A world: groups, members in some of them, and categories (some
  # subcategories) restricted to some groups, each with a thread whose
  # body holds a word only it has.
  defp world do
    gen all(
          groups <- integer(1..3),
          members <- list_of(list_of(integer(0..2), max_length: 3), min_length: 1, max_length: 3),
          categories <-
            list_of(
              {one_of([constant(nil), integer(0..5)]), list_of(integer(0..2), max_length: 2)},
              min_length: 1,
              max_length: 6
            )
        ) do
      %{groups: groups, members: members, categories: categories}
    end
  end

  defp build(%{groups: groups, members: members, categories: specs}, admin) do
    groups =
      for n <- 1..groups do
        {:ok, group} =
          Groups.create_group(%{name: "g#{n}x#{System.unique_integer([:positive])}"}, admin)

        group
      end

    users =
      for member_of <- members do
        user = user_fixture()

        for g <- Enum.uniq(member_of),
            g < length(groups),
            do: {:ok, _} = Groups.add_member(Enum.at(groups, g), user.username, admin)

        user
      end

    categories =
      Enum.reduce(specs, [], fn {parent, restricted}, made ->
        # A parent among the top-level categories made so far, if any.
        tops = Enum.filter(made, &is_nil(&1.parent_id))
        parent = parent && tops != [] && Enum.at(tops, rem(parent, length(tops)))
        role_ids = for g <- Enum.uniq(restricted), g < length(groups), do: Enum.at(groups, g).id

        attrs = %{title: "Cat #{System.unique_integer([:positive])}", role_ids: role_ids}
        attrs = if parent, do: Map.put(attrs, :parent_id, parent.id), else: attrs
        {:ok, category} = Discussion.create_category(attrs)
        made ++ [category]
      end)

    threads =
      for category <- categories do
        word = "zq#{System.unique_integer([:positive])}"

        {:ok, thread} =
          Discussion.create_thread(category, admin, %{
            title: "About #{word}",
            body: "The word #{word} here."
          })

        {thread, word}
      end

    %{users: [nil, admin | users], categories: categories, threads: threads}
  end

  defp readable_ids(user) do
    from(t in Thread, as: :thread, select: t.id)
    |> Policy.readable_threads(user)
    |> Repo.all()
    |> MapSet.new()
  end

  test "the thread rule, the list rules and search agree for everyone" do
    admin = admin_fixture()

    check all(spec <- world(), max_runs: runs(12)) do
      Repo.transact(fn ->
        %{users: users, categories: categories, threads: threads} = build(spec, admin)
        category_ids = MapSet.new(categories, & &1.id)

        for user <- users do
          readable = readable_ids(user)

          visible_categories =
            from(c in Category, select: c.id)
            |> Policy.readable_categories(user)
            |> Repo.all()
            |> MapSet.new()
            |> MapSet.intersection(category_ids)

          for category <- categories do
            assert can?(user, :view_category, category) ==
                     MapSet.member?(visible_categories, category.id)
          end

          for {thread, word} <- threads do
            allowed? = can?(user, :view_thread, thread)

            assert allowed? == MapSet.member?(readable, thread.id),
                   "rule and query disagree for #{inspect(user && user.username)}"

            # Search finds the thread exactly when the user may read it,
            # with or without its category's filter.
            category = Enum.find(categories, &(&1.id == thread.category_id))

            for query <- [
                  word,
                  "#{word} category:#{category.slug}",
                  "#{word} in:title",
                  "#{word} order:latest"
                ] do
              found = Search.run(Search.parse(query), user).entries |> Enum.map(& &1.thread.id)

              assert thread.id in found == allowed?,
                     "search #{inspect(query)} for #{inspect(user && user.username)}"

              assert Enum.all?(found, &MapSet.member?(readable, &1))
            end
          end

          # A category filter for a category the user can't see finds nothing.
          for category <- categories, not can?(user, :view_category, category) do
            assert Search.run(Search.parse("zq category:#{category.slug}"), user).entries == []

            assert Search.run(Search.parse("", %{"category" => category.slug}), user).entries ==
                     []
          end
        end

        {:error, :rollback}
      end)
    end
  end

  describe "search queries" do
    property "parse/2 is total, and run/3 never raises" do
      user = user_fixture()

      check all(
              query <-
                one_of([
                  adversarial_text(),
                  any_text(),
                  map(adversarial_text(3), &("category:" <> &1)),
                  map(adversarial_text(3), &("@" <> &1))
                ]),
              controls <-
                optional_map(%{
                  "category" => adversarial_text(2),
                  "tag" => adversarial_text(2),
                  "user" => adversarial_text(2),
                  "order" => member_of(["latest", "x"]),
                  "in" => constant("title"),
                  "muted" => constant("include")
                }),
              max_runs: runs(150)
            ) do
        search = Search.parse(query, controls)
        assert %Search{} = search

        for viewer <- [nil, user] do
          assert %Scrivener.Page{} = Search.run(search, viewer)
        end
      end
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "search stays total" do
      check all(
              query <- one_of([any_text(), adversarial_text(40), long_string(2_000)]),
              max_runs: fuzz_runs()
            ) do
        assert %Scrivener.Page{} = Search.run(Search.parse(query), nil)
      end
    end
  end
end
