defmodule FirestormWeb.Forums.PostDeletionTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 0, thread_fixture: 2]

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Notification, Policy}
  alias FirestormWeb.Web.Api.V1.PostJSON

  setup do
    author = user_fixture()
    replier = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, author)
    {:ok, reply} = Forums.create_post(thread, replier, %{body: "regrettable https://x.example"})
    %{author: author, replier: replier, category: category, thread: thread, reply: reply}
  end

  test "a deleted reply keeps its row but leaves counts and lists", ctx do
    %{author: author, replier: replier, category: category, thread: thread, reply: reply} = ctx
    Forums.mark_thread_read(author, thread)
    {:ok, _} = Forums.create_post(thread, replier, %{body: "second"})
    [%{posts_count: 3, unread_count: 1}] = Forums.list_threads(category, author)

    Forums.subscribe("forums:thread:#{thread.id}")
    assert {:ok, deleted} = Forums.delete_post(reply, replier)
    assert deleted.deleted_at
    assert deleted.deleted_by_id == replier.id
    assert_receive {:post_deleted, %{id: id}} when id == reply.id

    assert [%{posts_count: 2, unread_count: 1}] = Forums.list_threads(category, author)
    assert Forums.user_posts(replier, %{page: 1}).entries |> Enum.map(& &1.body) == ["second"]
    assert Forums.decorate_post_oembeds(deleted).oembeds == []
    assert %{body: "", deleted: true} = PostJSON.data(deleted)

    assert {:ok, restored} = Forums.restore_post(deleted)
    assert restored.deleted_at == nil
    assert [%{posts_count: 3}] = Forums.list_threads(category, author)
  end

  test "deleted replies don't make a thread Unread or rank it in Top", ctx do
    %{author: author, replier: replier, thread: thread, reply: reply} = ctx
    other = thread_fixture(category_fixture(), author)
    Forums.mark_thread_read(author, thread)
    {:ok, late} = Forums.create_post(thread, replier, %{body: "late"})
    assert [_] = Forums.unread_threads(author)

    {:ok, _} = Forums.delete_post(late, replier)
    assert Forums.unread_threads(author) == []

    {:ok, _} = Forums.delete_post(reply, replier)
    {:ok, _} = Forums.create_post(other, replier, %{body: "a reply that counts"})
    assert [%{id: first_id} | _] = Forums.top_threads("all", nil)
    assert first_id == other.id
  end

  test "the first post can't be deleted on its own", %{author: author, thread: thread} do
    [first] = Repo.preload(thread, :posts).posts
    assert {:error, :first_post} = Forums.delete_post(first, author)
  end

  test "deleting removes the post's notifications", %{author: author, thread: thread} = ctx do
    {:ok, _} =
      Forums.notify(author, Notification.for_post("new_post", thread, ctx.reply, ctx.replier))

    {:ok, _} = Forums.delete_post(ctx.reply, ctx.replier)
    assert Forums.notifications_for(author) == []
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

    {:ok, closed} = Forums.close_thread(thread, true)

    assert {:error, :unauthorized} =
             Policy.authorize(:delete_post, replier, %{params | thread: closed})

    {:ok, deleted} = Forums.delete_post(reply, admin)

    for action <- [:edit_post, :delete_post] do
      assert {:error, :unauthorized} =
               Policy.authorize(action, admin, %{post: deleted, thread: thread})
    end
  end
end
