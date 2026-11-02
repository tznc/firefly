defmodule FireflyWeb.Forums.PostDeletionTest do
  use Firefly.DataCase

  import Firefly.Fixtures,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 0, thread_fixture: 2]

  alias Firefly.{Discussion, Notifications}
  alias Firefly.Discussion.Policy
  alias Firefly.Notifications.Notification
  alias FireflyWeb.Api.V1.PostJSON

  setup do
    author = user_fixture()
    replier = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, author)

    {:ok, reply} =
      Discussion.create_post(thread, replier, %{body: "regrettable https://x.example"})

    %{author: author, replier: replier, category: category, thread: thread, reply: reply}
  end

  test "a deleted reply keeps its row but leaves counts and lists", ctx do
    %{author: author, replier: replier, category: category, thread: thread, reply: reply} = ctx
    Discussion.mark_thread_read(author, thread)
    {:ok, _} = Discussion.create_post(thread, replier, %{body: "second"})
    [%{posts_count: 3, unread_count: 1}] = Discussion.list_threads(category, author)

    Discussion.subscribe("forums:thread:#{thread.id}")
    assert {:ok, deleted} = Discussion.delete_post(reply, replier)
    assert deleted.deleted_at
    assert deleted.deleted_by_id == replier.id
    assert_receive {:post_deleted, %{id: id}} when id == reply.id

    assert [%{posts_count: 2, unread_count: 1}] = Discussion.list_threads(category, author)

    assert Discussion.user_posts(replier, nil, %{page: 1}).entries |> Enum.map(& &1.body) == [
             "second"
           ]

    assert Discussion.decorate_post_oembeds(deleted).oembeds == []
    assert %{body: "", deleted: true} = PostJSON.data(deleted)

    assert {:ok, restored} = Discussion.restore_post(deleted, admin_fixture())
    assert restored.deleted_at == nil
    assert [%{posts_count: 3}] = Discussion.list_threads(category, author)
  end

  test "deleted replies don't make a thread Unread or rank it in Top", ctx do
    %{author: author, replier: replier, thread: thread, reply: reply} = ctx
    other = thread_fixture(category_fixture(), author)
    Discussion.mark_thread_read(author, thread)
    {:ok, late} = Discussion.create_post(thread, replier, %{body: "late"})
    assert [_] = Discussion.unread_threads(author)

    {:ok, _} = Discussion.delete_post(late, replier)
    assert Discussion.unread_threads(author) == []

    {:ok, _} = Discussion.delete_post(reply, replier)
    {:ok, _} = Discussion.create_post(other, replier, %{body: "a reply that counts"})
    assert [%{id: first_id} | _] = Discussion.top_threads("all", nil)
    assert first_id == other.id
  end

  test "the first post can't be deleted on its own", %{author: author, thread: thread} do
    [first] = Repo.preload(thread, :posts).posts
    assert {:error, :first_post} = Discussion.delete_post(first, author)
  end

  test "deleting removes the post's notifications", %{author: author, thread: thread} = ctx do
    {:ok, _} =
      Notifications.notify(
        author,
        Notification.for_post("new_post", thread, ctx.reply, ctx.replier)
      )

    {:ok, _} = Discussion.delete_post(ctx.reply, ctx.replier)
    assert Notifications.notifications_for(author) == []
  end

  test "authors (while open) and admins may delete; only admins restore", ctx do
    %{replier: replier, thread: thread, reply: reply} = ctx
    admin = admin_fixture()
    params = %{post: reply, thread: thread}

    assert :ok = Policy.authorize(:delete_post, replier, params)
    assert :ok = Policy.authorize(:delete_post, admin, params)
    assert {:error, :unauthorized} = Policy.authorize(:delete_post, ctx.author, params)
    assert {:error, :unauthorized} = Policy.authorize(:restore_post, replier, %{})
    assert :ok = Policy.authorize(:restore_post, admin, %{})

    {:ok, closed} = Discussion.close_thread(thread, true, admin)

    assert {:error, :unauthorized} =
             Policy.authorize(:delete_post, replier, %{params | thread: closed})

    {:ok, deleted} = Discussion.delete_post(reply, admin)

    for action <- [:edit_post, :delete_post] do
      assert {:error, :unauthorized} =
               Policy.authorize(action, admin, %{post: deleted, thread: thread})
    end
  end
end
