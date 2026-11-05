defmodule Firefly.TagsPropertyTest do
  @moduledoc """
  Properties of tags (`Firefly.Discussion.Tags` and tagging threads), over
  random sequences of making and removing synonyms and tagging threads:
  a synonym never stands for another synonym, no thread is ever tagged
  with a synonym, `canonical_name/1` always names a canonical tag, and a
  member's tags respect the groups (at most one of a one-per-thread
  group, no staff-only tag added).
  """
  # Sync: it makes admins (the shared admin role).
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Discussion
  alias Firefly.Discussion.{Tag, Tags}

  @names ~w(ta tb tc td te)

  defp command do
    one_of([
      tuple({constant(:synonym), member_of(@names), member_of(@names)}),
      tuple({constant(:unsynonym), member_of(@names)}),
      tuple({constant(:thread), list_of(member_of(@names), max_length: 3), boolean()})
    ])
  end

  defp synonym?(name),
    do: match?(%Tag{synonym_of_id: id} when id != nil, Repo.get_by(Tag, name: name))

  defp assert_invariants do
    tags = Repo.all(Tag)
    by_id = Map.new(tags, &{&1.id, &1})

    for %Tag{synonym_of_id: id} = tag when id != nil <- tags do
      assert by_id[id].synonym_of_id == nil, "#{tag.name} is a synonym of a synonym"
    end

    synonyms = for %Tag{synonym_of_id: id} = t when id != nil <- tags, do: t.id

    tagged_with_synonym =
      Repo.all(
        from(tt in "forums_threads_tags", where: tt.tag_id in ^synonyms, select: tt.thread_id)
      )

    assert tagged_with_synonym == []

    for name <- @names, do: refute(synonym?(Tags.canonical_name(name)))
  end

  test "synonyms and tagging keep the invariants" do
    admin = admin_fixture()
    member = user_fixture()

    check all(commands <- list_of(command(), min_length: 1, max_length: 10), max_runs: runs(25)) do
      category = category_fixture("Tags #{System.unique_integer([:positive])}")

      for command <- commands do
        case command do
          {:synonym, a, b} ->
            case Tags.make_synonym(a, b, admin) do
              {:ok, _} -> :ok
              {:error, reason} -> assert is_binary(Tags.message(reason))
            end

          {:unsynonym, a} ->
            if tag = Repo.get_by(Tag, name: a), do: {:ok, _} = Tags.remove_synonym(tag, admin)

          {:thread, names, staff?} ->
            author = if staff?, do: admin, else: member

            attrs = %{
              title: "Tagged #{System.unique_integer([:positive])}",
              body: "Tags.",
              tags: Enum.join(names, ", ")
            }

            case Discussion.create_thread(category, author, attrs) do
              {:ok, _} -> :ok
              {:error, %Ecto.Changeset{}} -> :ok
            end
        end

        assert_invariants()
      end
    end
  end

  test "a member's tags respect one-per-thread and staff-only groups" do
    admin = admin_fixture()
    member = user_fixture()
    category = category_fixture("Grouped")

    {:ok, _} =
      Tags.create_group(
        %{"name" => "Status", "one_per_thread" => "true", "tags" => "open, closed, stale"},
        admin
      )

    {:ok, _} =
      Tags.create_group(%{"name" => "Staff", "staff_only" => "true", "tags" => "official"}, admin)

    staff_only = ["official"]
    one_per = ~w(open closed stale)

    check all(
            names <-
              list_of(member_of(one_per ++ staff_only ++ ~w(misc)), min_length: 1, max_length: 4),
            staff? <- boolean(),
            max_runs: runs(60)
          ) do
      author = if staff?, do: admin, else: member

      attrs = %{
        title: "Grouped #{System.unique_integer([:positive])}",
        body: "Tags.",
        tags: Enum.join(names, ", ")
      }

      case Discussion.create_thread(category, author, attrs) do
        {:ok, thread} ->
          tags =
            thread |> Repo.preload(:tags, force: true) |> Map.fetch!(:tags) |> Enum.map(& &1.name)

          assert Enum.count(tags, &(&1 in one_per)) <= 1
          if not staff?, do: assert(Enum.all?(tags, &(&1 not in staff_only)))

        {:error, %Ecto.Changeset{} = changeset} ->
          uniq = Enum.uniq(names)

          assert Enum.count(uniq, &(&1 in one_per)) > 1 or
                   (not staff? and Enum.any?(uniq, &(&1 in staff_only))) or
                   changeset.errors[:tags] == nil
      end
    end
  end

  property "tag names from any text are parsed or refused, never a crash" do
    admin = admin_fixture()

    check all(
            a <- one_of([adversarial_text(3), member_of(@names)]),
            b <- one_of([adversarial_text(3), member_of(@names)]),
            max_runs: runs(100)
          ) do
      case Tags.make_synonym(a, b, admin) do
        {:ok, _} -> assert_invariants()
        {:error, reason} -> assert is_binary(Tags.message(reason))
      end

      assert is_binary(Tags.canonical_name(String.replace(a, <<0>>, "")))
    end
  end
end
