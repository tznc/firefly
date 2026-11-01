defmodule FirestormWeb.Forums.LikesTest do
  use FirestormWeb.DataCase
  use Bamboo.Test

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 1, admin_fixture: 0, category_fixture: 0, thread_fixture: 3]

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Policy, PostLike}

  setup do
    author = user_fixture(%{username: "author"})
    thread = thread_fixture(category_fixture(), author, %{title: "Likeable"})
    [post] = Repo.preload(thread, :posts).posts
    %{author: author, thread: thread, post: post}
  end

  test "one like per user per post; unliking removes it", %{post: post} do
    bob = user_fixture(%{username: "bob"})
    Forums.subscribe("forums:thread:#{post.thread_id}")

    assert :ok = Forums.like_post(post, bob)
    assert_receive {:post_likes_changed, _}
    assert :ok = Forums.like_post(post, bob)
    refute_receive {:post_likes_changed, _}

    assert Forums.liked?(post, bob)
    assert %{} = likers = Forums.likers([post])
    assert [%{username: "bob"}] = likers[post.id]

    assert :ok = Forums.unlike_post(post, bob)
    assert_receive {:post_likes_changed, _}
    refute Forums.liked?(post, bob)
    assert Repo.all(PostLike) == []
  end

  test "the database refuses duplicate likes", %{post: post} do
    bob = user_fixture(%{username: "bob"})
    Repo.insert!(%PostLike{post_id: post.id, user_id: bob.id})

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%PostLike{post_id: post.id, user_id: bob.id})
    end
  end

  test "likes notify the author once while unread, consolidated", ctx do
    %{author: author, post: post} = ctx
    [bob, carol, dave] = for name <- ~w(bob carol dave), do: user_fixture(%{username: name})

    Forums.like_post(post, bob)
    assert [notification] = Forums.notifications_for(author)
    assert notification.kind == "liked"
    assert notification.subject == ~s(@bob liked your post in "Likeable")

    Forums.like_post(post, carol)

    assert [%{subject: ~s(@carol and 1 other liked your post in "Likeable")}] =
             Forums.notifications_for(author)

    Forums.like_post(post, dave)

    assert [%{subject: ~s(@dave and 2 others liked your post in "Likeable")} = notification] =
             Forums.notifications_for(author)

    # Once read, the next like is news again.
    {:ok, _} = Forums.mark_notification_read(notification)
    Forums.unlike_post(post, bob)
    Forums.like_post(post, bob)
    assert [%{read_at: nil}, %{}] = Forums.notifications_for(author)
    assert_no_emails_delivered()
  end

  test "likes break ties in Top", %{author: author, thread: thread} do
    other = thread_fixture(category_fixture(), author, %{title: "Also busy"})
    fan = user_fixture(%{username: "fan"})

    # Both have one post; the newer one leads until the older gets a like.
    assert [%{id: first} | _] = Forums.top_threads("week", nil)
    assert first == other.id

    [post] = Repo.preload(thread, :posts).posts
    Forums.like_post(post, fan)
    assert [%{id: first} | _] = Forums.top_threads("week", nil)
    assert first == thread.id

    # More posts still beat more likes.
    {:ok, _} = Forums.create_post(other, fan, %{body: "busier"})
    assert [%{id: first} | _] = Forums.top_threads("week", nil)
    assert first == other.id
  end

  test ":like_post: others' visible posts, outside archived threads", ctx do
    %{author: author, thread: thread, post: post} = ctx
    bob = user_fixture(%{username: "bob"})
    params = %{post: post, thread: thread}

    assert :ok = Policy.authorize(:like_post, bob, params)
    assert {:error, :unauthorized} = Policy.authorize(:like_post, author, params)
    assert {:error, :unauthenticated} = Policy.authorize(:like_post, nil, params)

    {:ok, reply} = Forums.create_post(thread, author, %{body: "reply"})
    {:ok, archived} = Forums.archive_thread(thread, true)

    assert {:error, :unauthorized} =
             Policy.authorize(:like_post, bob, %{params | thread: archived})

    {:ok, deleted} = Forums.delete_post(reply, admin_fixture())

    assert {:error, :unauthorized} =
             Policy.authorize(:like_post, bob, %{post: deleted, thread: thread})
  end
end
