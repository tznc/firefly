defmodule Firefly.BulkActionsTest do
  use Firefly.DataCase

  alias Firefly.{Discussion, SiteSettings}
  alias Firefly.Discussion.Thread
  alias Firefly.Moderation.{BulkActions, Review, StaffAction}

  import Firefly.Fixtures

  setup do
    admin = admin_fixture()
    author = user_fixture()
    category = category_fixture()

    threads =
      for title <- ["One", "Two", "Three"],
          do: thread_fixture(category, author, %{title: title})

    %{admin: admin, author: author, category: category, threads: threads}
  end

  defp ids(threads), do: Enum.map(threads, & &1.id)
  defp reload(thread), do: Repo.get(Thread, thread.id)

  defp logged(action),
    do: Repo.aggregate(where(StaffAction, [a], a.action == ^action), :count)

  test "admins close, pin, archive and delete many threads, each logged", ctx do
    assert {:ok, %{done: 3, skipped: 0}} =
             BulkActions.perform(ctx.admin, ids(ctx.threads), "close")

    assert Enum.all?(ctx.threads, &Thread.closed?(reload(&1)))
    assert logged("thread.close") == 3

    assert {:ok, %{done: 2}} = BulkActions.perform(ctx.admin, ids(tl(ctx.threads)), "pin")
    assert Thread.pinned?(reload(List.last(ctx.threads)))

    assert {:ok, %{done: 3}} = BulkActions.perform(ctx.admin, ids(ctx.threads), "archive")
    assert logged("thread.archive") == 3

    assert {:ok, %{done: 3}} = BulkActions.perform(ctx.admin, ids(ctx.threads), "delete")
    assert Enum.all?(ctx.threads, &is_nil(reload(&1)))
    assert logged("thread.delete") == 3
  end

  test "moves threads and adds or removes tags", ctx do
    other = category_fixture("Erlang")

    assert {:ok, %{done: 3}} =
             BulkActions.perform(ctx.admin, ids(ctx.threads), "move", %{
               "category_id" => to_string(other.id)
             })

    assert Enum.all?(ctx.threads, &(reload(&1).category_id == other.id))

    assert {:ok, %{done: 3}} =
             BulkActions.perform(ctx.admin, ids(ctx.threads), "add_tags", %{"tags" => "otp, beam"})

    assert {:ok, %{done: 3}} =
             BulkActions.perform(ctx.admin, ids(ctx.threads), "remove_tags", %{"tags" => "otp"})

    names = ctx.threads |> hd() |> reload() |> Repo.preload(:tags) |> Map.get(:tags)
    assert Enum.map(names, & &1.name) == ["beam"]

    assert {:error, :no_category} =
             BulkActions.perform(ctx.admin, ids(ctx.threads), "move", %{"category_id" => "x"})
  end

  test "a failing thread rolls the whole batch back", ctx do
    SiteSettings.update(%{"max_tags_per_thread" => "1"}, ctx.admin)
    [first | _] = ctx.threads
    {:ok, _} = Discussion.update_thread(first, %{tags: "otp"}, ctx.admin)

    assert {:error, {%Thread{id: id}, _changeset} = error} =
             BulkActions.perform(ctx.admin, ids(ctx.threads), "add_tags", %{"tags" => "beam"})

    assert id == first.id
    assert BulkActions.message(error) =~ "Nothing changed"

    refute ctx.threads
           |> List.last()
           |> reload()
           |> Repo.preload(:tags)
           |> Map.get(:tags)
           |> Enum.any?()
  end

  test "members only mark threads read; staff actions skip them", ctx do
    member = user_fixture()

    assert BulkActions.actions_for(member) == ["mark_read"]
    assert "delete" in BulkActions.actions_for(ctx.admin)

    assert {:ok, %{done: 0, skipped: 3}} = BulkActions.perform(member, ids(ctx.threads), "close")
    refute Enum.any?(ctx.threads, &Thread.closed?(reload(&1)))

    assert {:ok, %{done: 3}} = BulkActions.perform(member, ids(ctx.threads), "mark_read")
    assert Discussion.unread_threads(member) == []
    assert Enum.all?(ctx.threads, &Discussion.thread_read(member, &1))
  end

  test "leaders (trust level 4) close but don't delete", ctx do
    leader = user_fixture()
    leader = Repo.update!(change(leader, trust_level: 4))

    assert {:ok, %{done: 3}} = BulkActions.perform(leader, ids(ctx.threads), "close")
    assert {:ok, %{done: 0, skipped: 3}} = BulkActions.perform(leader, ids(ctx.threads), "delete")
  end

  test "approves and rejects queued posts in bulk", ctx do
    SiteSettings.update(%{"approve_new_user_posts" => "5"}, ctx.admin)
    newbie = user_fixture()
    [thread | _] = ctx.threads

    posts =
      for n <- 1..3 do
        {:ok, post} = Discussion.create_post(thread, newbie, %{body: "Reply #{n}"})
        post
      end

    [a, b, c] = Enum.map(posts, & &1.id)

    assert {:ok, 2} = Review.approve_many([a, b], ctx.admin)
    assert {:error, :reason_required} = Review.reject_many([c], ctx.admin, " ")
    assert {:ok, 1} = Review.reject_many([a, c], ctx.admin, "Off-topic")
    assert Review.queued_posts() == []
    assert logged("post.approve") == 2 and logged("post.reject") == 1
  end
end
