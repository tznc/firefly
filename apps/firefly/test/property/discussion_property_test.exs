defmodule Firefly.DiscussionPropertyTest do
  @moduledoc """
  Properties of `Firefly.Discussion` (and the topic tools that move its
  posts): any sequence of category moves keeps each list of siblings in
  the model's order, numbered 0, 1, 2... where it was renumbered, and
  categories one level deep; splits and merges conserve posts and keep
  each thread's first post; unread counts never go negative; slugs are
  always URL-safe.
  """
  # Sync: it holds the shared "admin" role (admin_fixture/1) for its whole run.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Discussion
  alias Firefly.Discussion.{Category, Post, Thread}
  alias Firefly.Moderation.TopicTools

  describe "category moves" do
    # The model: each parent's (nil: top level) children, in order.
    defp siblings_in_db do
      Category
      |> Repo.all()
      |> Enum.group_by(& &1.parent_id)
      |> Map.new(fn {parent, categories} ->
        {parent, categories |> Enum.sort_by(&{&1.position, &1.title, &1.id}) |> Enum.map(& &1.id)}
      end)
    end

    defp parent_of(model, id),
      do: Enum.find_value(model, fn {parent, ids} -> if id in ids, do: {:ok, parent} end)

    # What place_category/4 should do to the model: `{:ok, model}` or :error.
    defp expect(model, id, parent, index) do
      {:ok, current} = parent_of(model, id)
      children? = Map.get(model, id, []) != []

      cond do
        parent == current ->
          {:ok, insert(model, id, current, parent, index)}

        parent == id ->
          :error

        parent != nil and match?({:ok, p} when p != nil, parent_of(model, parent)) ->
          :error

        parent != nil and children? ->
          :error

        true ->
          {:ok, insert(model, id, current, parent, index)}
      end
    end

    defp insert(model, id, from, to, index) do
      model = Map.update!(model, from, &List.delete(&1, id))
      list = Map.get(model, to, [])
      Map.put(model, to, List.insert_at(list, index |> max(0) |> min(length(list)), id))
    end

    test "any sequence keeps the model's order, contiguous positions and one level" do
      admin = admin_fixture()

      check all(
              count <- integer(2..5),
              moves <-
                list_of({integer(0..4), one_of([constant(nil), integer(0..4)]), integer(-2..6)},
                  min_length: 1,
                  max_length: 12
                ),
              max_runs: runs(12)
            ) do
        ids =
          for n <- 1..count do
            {:ok, c} =
              Discussion.create_category(%{title: "C#{n} #{System.unique_integer([:positive])}"})

            c.id
          end

        Enum.reduce(moves, {siblings_in_db(), MapSet.new()}, fn {who, parent, index},
                                                                {model, touched} ->
          id = Enum.at(ids, rem(who, count))
          parent = parent && Enum.at(ids, rem(parent, count))
          {:ok, from} = parent_of(model, id)
          result = Discussion.place_category(Repo.get!(Category, id), parent, index, admin)

          case expect(model, id, parent, index) do
            {:ok, expected} ->
              assert {:ok, %Category{}} = result
              actual = siblings_in_db()
              touched = MapSet.union(touched, MapSet.new([from, parent]))

              for {parent_id, ids} <- expected, ids != [] do
                assert actual[parent_id] == ids, "under #{inspect(parent_id)}"
              end

              # Renumbered lists are 0, 1, 2...
              for parent_id <- touched, ids = actual[parent_id] || [] do
                positions = Enum.map(ids, &Repo.get!(Category, &1).position)
                assert positions == Enum.to_list(0..(length(ids) - 1)//1)
              end

              # One level deep.
              for %Category{parent_id: p} when p != nil <- Repo.all(Category) do
                assert Repo.get!(Category, p).parent_id == nil
              end

              {expected, touched}

            :error ->
              assert {:error, %Ecto.Changeset{}} = result

              assert siblings_in_db() |> Map.reject(fn {_, ids} -> ids == [] end) ==
                       Map.reject(model, fn {_, ids} -> ids == [] end)

              {model, touched}
          end
        end)
      end
    end
  end

  describe "slugs" do
    property "categories and threads always get a URL-safe slug" do
      user = user_fixture()
      {:ok, category} = Discussion.create_category(%{title: "Home"})

      check all(title <- title(), max_runs: runs(60)) do
        case Discussion.create_category(%{title: title}) do
          {:ok, created} ->
            assert created.slug =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, inspect(created.slug)

          {:error, %Ecto.Changeset{}} ->
            :ok
        end

        case Discussion.create_thread(category, user, %{title: title, body: "A body long enough."}) do
          {:ok, thread} ->
            assert thread.slug =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, inspect(thread.slug)

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "splits and merges" do
    defp posts_of(thread_id),
      do:
        Repo.all(
          from(p in Post,
            where: p.thread_id == ^thread_id,
            order_by: [p.inserted_at, p.id],
            select: p.id
          )
        )

    test "conserve posts and keep each thread's first post" do
      admin = admin_fixture()
      reader = user_fixture()
      category = category_fixture("Moves")

      check all(
              sizes <- list_of(integer(1..4), min_length: 2, max_length: 3),
              ops <-
                list_of(
                  one_of([
                    tuple({constant(:merge), integer(0..2), integer(0..2)}),
                    tuple(
                      {constant(:split), integer(0..2),
                       list_of(integer(0..5), min_length: 1, max_length: 3),
                       one_of([constant(:new), integer(0..2)])}
                    ),
                    tuple({constant(:read), integer(0..2)}),
                    tuple({constant(:reply), integer(0..2)})
                  ]),
                  min_length: 1,
                  max_length: 8
                ),
              max_runs: runs(10)
            ) do
        threads =
          for size <- sizes do
            thread =
              thread_fixture(category, admin, %{
                title: "Thread #{System.unique_integer([:positive])}"
              })

            for _ <- 2..size//1,
                do: {:ok, _} = Discussion.create_post(thread, admin, %{body: "A reply here."})

            thread.id
          end

        all_posts = fn ids -> ids |> Enum.flat_map(&posts_of/1) |> Enum.sort() end
        heads = Map.new(threads, &{&1, hd(posts_of(&1))})

        Enum.reduce(ops, {threads, all_posts.(threads), heads}, fn op, {threads, posts, heads} ->
          at = &Enum.at(threads, rem(&1, length(threads)))
          live = fn -> Enum.reject(threads, &Thread.merged?(Repo.get!(Thread, &1))) end

          {threads, posts, heads} =
            case op do
              {:merge, a, b} ->
                TopicTools.merge(Repo.get!(Thread, at.(a)), Repo.get!(Thread, at.(b)), admin)
                {threads, posts, heads}

              {:split, a, picks, target} ->
                source = at.(a)
                ids = posts_of(source)
                # A merged thread has none left.
                picked =
                  if ids == [], do: [], else: Enum.map(picks, &Enum.at(ids, rem(&1, length(ids))))

                destination =
                  if target == :new,
                    do:
                      {:new,
                       %{
                         "title" => "Split #{System.unique_integer([:positive])}",
                         "category_id" => category.id
                       }},
                    else: {:existing, Repo.get!(Thread, at.(target))}

                case TopicTools.split(Repo.get!(Thread, source), picked, destination, admin) do
                  {:ok, %Thread{id: new_id}} ->
                    if new_id in threads,
                      do: {threads, posts, heads},
                      else:
                        {threads ++ [new_id], posts, Map.put(heads, new_id, hd(posts_of(new_id)))}

                  {:error, _} ->
                    {threads, posts, heads}
                end

              {:read, a} ->
                {:ok, _} = Discussion.mark_thread_read(reader, Repo.get!(Thread, at.(a)))
                {threads, posts, heads}

              {:reply, a} ->
                thread = Repo.get!(Thread, at.(a))

                if Thread.merged?(thread) do
                  {threads, posts, heads}
                else
                  {:ok, post} = Discussion.create_post(thread, admin, %{body: "Another reply."})
                  {threads, Enum.sort([post.id | posts]), heads}
                end
            end

          # Every post is still in exactly one thread.
          assert all_posts.(threads) == posts

          for id <- live.() do
            assert [head | _] = posts_of(id)
            assert head == heads[id], "thread #{id}'s first post changed"
          end

          for thread <- Discussion.recent_threads(category, reader) do
            assert thread.unread_count >= 0
            assert thread.unread_count <= thread.posts_count
          end

          {threads, posts, heads}
        end)
      end
    end
  end

  # Found by the slug property: Postgres refuses NUL in text columns, so
  # saving one raised. Casting strips it (see Firefly.Changeset).
  test "nul: a title holding a NUL is saved without it" do
    assert {:ok, category} = Discussion.create_category(%{title: <<"a", 0>>})
    assert Repo.reload!(category).title == "a"
  end
end
