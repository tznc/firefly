defmodule FirestormWeb.SearchTest do
  use FirestormWeb.DataCase

  alias FirestormWeb.{Forums, Search}

  setup do
    {:ok, elixir} = Forums.create_category(%{title: "Elixir"})
    {:ok, otp} = Forums.create_category(%{title: "OTP", parent_id: elixir.id})
    {:ok, other} = Forums.create_category(%{title: "Other"})
    alice = user("alice")
    bob = user("bob")

    {:ok, supervisors} =
      Forums.create_thread(otp, alice, %{
        title: "Supervisors explained",
        body: "Let it crash.",
        tags: "beam"
      })

    {:ok, reply} =
      Forums.create_post(supervisors, bob, %{body: "Supervision trees restart crashed children."})

    {:ok, cooking} =
      Forums.create_thread(other, bob, %{title: "Cooking", body: "Crash-free pancakes"})

    %{
      elixir: elixir,
      alice: alice,
      bob: bob,
      supervisors: supervisors,
      reply: reply,
      cooking: cooking
    }
  end

  defp user(name) do
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  defp search(q, controls \\ %{}), do: Search.run(Search.parse(q, controls), nil)
  defp post_ids(q, controls \\ %{}), do: search(q, controls).entries |> Enum.map(& &1.post.id)
  defp first_post_id(thread), do: hd(Repo.preload(thread, :posts).posts).id

  test "parse/2 reads inline filters; controls win" do
    assert %Search{
             terms: ~s(supervisor "let it"),
             category: "elixir",
             tag: "beam",
             user: "Alice",
             in_title: true,
             order: "latest"
           } =
             Search.parse(
               ~s(supervisor category:Elixir "let it" tag:beam @Alice in:title order:latest)
             )

    assert %Search{category: "other", user: "bob", order: "relevance"} =
             Search.parse("x category:elixir @alice", %{
               "category" => "other",
               "user" => "@bob",
               "tag" => "",
               "order" => "bogus"
             })
  end

  test "matches post bodies (stemmed) and thread titles via the first post", ctx do
    assert post_ids("restarting") == [ctx.reply.id]
    assert post_ids("explained") == [first_post_id(ctx.supervisors)]

    assert post_ids("crash") |> Enum.sort() ==
             Enum.sort([first_post_id(ctx.supervisors), ctx.reply.id, first_post_id(ctx.cooking)])

    assert post_ids("crash -pancakes") |> length() == 2
    # Words from the title and the first post together
    assert post_ids("supervisors crash") == [first_post_id(ctx.supervisors)]

    # Renaming re-indexes the first post
    {:ok, _} = Forums.update_thread(ctx.supervisors, %{"title" => "Trees"})
    assert post_ids("explained") == []

    assert post_ids("trees") |> Enum.sort() ==
             Enum.sort([first_post_id(ctx.supervisors), ctx.reply.id])

    assert post_ids("nothing-matches-this") == []
    assert search("").entries == []
  end

  test "filters by category (with subcategories), tag, author and title", ctx do
    first = first_post_id(ctx.supervisors)
    assert post_ids("crash category:elixir") |> Enum.sort() == Enum.sort([first, ctx.reply.id])
    assert post_ids("crash", %{"category" => "other"}) == [first_post_id(ctx.cooking)]
    assert post_ids("crash tag:BEAM") |> length() == 2

    assert post_ids("crash @Bob") |> Enum.sort() ==
             Enum.sort([ctx.reply.id, first_post_id(ctx.cooking)])

    assert post_ids("crash in:title") == []
    assert post_ids("supervisors in:title") == [first]

    # Filters alone list matching posts, newest first
    assert post_ids("@alice") == [first]
  end

  test "sorts by relevance or latest", ctx do
    {:ok, newer} = Forums.create_post(ctx.supervisors, ctx.alice, %{body: "a crash"})
    first = first_post_id(ctx.supervisors)

    # The (weightier) title match ranks the first post above newer posts
    assert hd(post_ids("supervisors or crash")) == first
    assert hd(post_ids("supervisors or crash order:latest")) == newer.id
  end

  test "leaves out deleted posts and archived threads", ctx do
    {:ok, _} = Forums.delete_post(ctx.reply, ctx.bob)
    assert post_ids("restarting") == []

    {:ok, _} = Forums.archive_thread(ctx.cooking, true)
    assert post_ids("pancakes") == []
  end

  test "headlines mark matches and escape everything else", ctx do
    {:ok, _} =
      Forums.create_post(ctx.supervisors, ctx.alice, %{
        body: "<script>alert(1)</script> \u0001 fish & <b>dangerous</b> chips"
      })

    [%{headline: headline}] = search("dangerous").entries
    assert headline =~ "<mark>dangerous</mark>"
    assert headline =~ "fish &amp; "
    refute headline =~ "<script>"
    refute headline =~ "<b>"
    refute headline =~ "\u0001"
  end
end
