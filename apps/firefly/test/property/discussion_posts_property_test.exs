defmodule Firefly.DiscussionPostsPropertyTest do
  @moduledoc """
  Properties of what members do with posts in `Firefly.Discussion`: a word
  diff gives back both texts; a post's edit history chains from its first
  body to its current one, and an edit from a stale copy is refused; likes
  match a set model over any sequence of likes and unlikes; and an accepted
  answer (`Firefly.Discussion.Solved`) matches a model over accepting,
  unaccepting and deleting replies.
  """
  # Sync: it makes threads in categories other tests list.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Discussion
  alias Firefly.Discussion.{Diff, Post, Solved, Thread}

  defp side(diff, keep), do: for({op, text} <- diff, op in [:eq, keep], into: "", do: text)

  # Bodies come from the database, so they're valid UTF-8.
  defp text, do: filter(one_of([any_text(), adversarial_text(), body()]), &String.valid?/1)

  property "a word diff gives back both texts" do
    check all(
            old <- text(),
            new <- text(),
            max_runs: runs(300)
          ) do
      diff = Diff.words(old, new)
      assert side(diff, :del) == old
      assert side(diff, :ins) == new
    end
  end

  defp body do
    map(
      list_of({member_of(~w(alpha beta gamma delta)), member_of([" ", "  ", "\n", "\n\n"])},
        min_length: 2,
        max_length: 12
      ),
      fn words -> words |> Enum.map_join(fn {w, s} -> w <> s end) |> String.trim() end
    )
  end

  defp first_post(thread),
    do: Repo.one!(from(p in Post, where: p.thread_id == ^thread.id, order_by: p.id, limit: 1))

  test "the edit history chains from the first body to the current one" do
    author = user_fixture()
    category = category_fixture("Edits")

    check all(first <- body(), edits <- list_of(body(), max_length: 5), max_runs: runs(30)) do
      thread = thread_fixture(category, author, %{body: first})
      post = first_post(thread)

      final =
        Enum.reduce(edits, post, fn new, post ->
          {:ok, edited} = Discussion.update_post(post, author, %{body: new})

          # A copy from before this edit is stale once the body changed.
          if new != post.body,
            do:
              assert(
                {:error, :edited_elsewhere} = Discussion.update_post(post, author, %{body: "x y"})
              )

          edited
        end)

      history = final |> Discussion.post_edits() |> Enum.reverse()
      bodies = Enum.dedup([first | edits])

      assert length(history) == length(bodies) - 1
      assert Enum.map(history, &side(&1.diff, :del)) == Enum.drop(bodies, -1)
      assert Enum.map(history, &side(&1.diff, :ins)) == Enum.drop(bodies, 1)
      assert final.body == List.last(bodies)
    end
  end

  test "likes match a set model" do
    author = user_fixture()
    likers = for _ <- 1..3, do: user_fixture()
    category = category_fixture("Likes")

    check all(
            commands <- list_of({member_of([:like, :unlike]), integer(0..2)}, max_length: 12),
            max_runs: runs(30)
          ) do
      post = category |> thread_fixture(author) |> first_post()

      model =
        Enum.reduce(commands, MapSet.new(), fn {op, i}, model ->
          user = Enum.at(likers, i)

          case op do
            :like ->
              Discussion.like_post(post, user)
              MapSet.put(model, i)

            :unlike ->
              Discussion.unlike_post(post, user)
              MapSet.delete(model, i)
          end
        end)

      for {user, i} <- Enum.with_index(likers),
          do: assert(Discussion.liked?(post, user) == MapSet.member?(model, i))

      ids = Discussion.likers([post]) |> Map.get(post.id, []) |> Enum.map(& &1.id)
      assert Enum.uniq(ids) == ids
      assert MapSet.new(ids) == MapSet.new(model, &Enum.at(likers, &1).id)
    end
  end

  test "an accepted answer matches a model of accepting, unaccepting and deleting" do
    author = user_fixture()
    repliers = for _ <- 1..3, do: user_fixture()

    {:ok, category} =
      Discussion.create_category(%{
        title: "Q&A #{System.unique_integer([:positive])}",
        allow_accepted_answers: true
      })

    check all(
            commands <-
              list_of(
                one_of([
                  tuple({constant(:accept), integer(0..2)}),
                  constant(:accept_first),
                  constant(:unaccept),
                  tuple({constant(:delete), integer(0..2)})
                ]),
                max_length: 10
              ),
            max_runs: runs(30)
          ) do
      thread = thread_fixture(category, author)
      first = first_post(thread)

      replies =
        for user <- repliers do
          {:ok, post} = Discussion.create_post(thread, user, %{body: "An answer, maybe."})
          post
        end

      {accepted, _deleted} =
        Enum.reduce(commands, {nil, MapSet.new()}, fn command, {accepted, deleted} ->
          case command do
            {:accept, i} ->
              result = Solved.accept(thread, Enum.at(replies, i), author)

              if i in deleted do
                assert {:error, _} = result
                {accepted, deleted}
              else
                assert {:ok, _} = result
                {i, deleted}
              end

            :accept_first ->
              assert {:error, :first_post} = Solved.accept(thread, first, author)
              {accepted, deleted}

            :unaccept ->
              case {accepted, Solved.unaccept(thread, author)} do
                {nil, result} -> assert {:error, :not_solved} = result
                {_, result} -> assert {:ok, _} = result
              end

              {nil, deleted}

            {:delete, i} ->
              post = Repo.get!(Post, Enum.at(replies, i).id)
              user = Enum.at(repliers, i)

              if i in deleted do
                {accepted, deleted}
              else
                {:ok, _} = Discussion.delete_post(post, user)
                {if(accepted == i, do: nil, else: accepted), MapSet.put(deleted, i)}
              end
          end
        end)

      expected = accepted && Enum.at(replies, accepted).id
      assert Repo.get!(Thread, thread.id).accepted_post_id == expected
    end
  end
end
