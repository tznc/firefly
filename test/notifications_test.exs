defmodule FirestormWeb.NotificationsTest do
  use FirestormWeb.DataCase
  use Bamboo.Test, shared: true

  alias FirestormWeb.{Forums, Notifications}
  alias FirestormWeb.Forums.Subscriptions

  setup do
    {:ok, _} = Notifications.start_link()

    {:ok, category} = Forums.create_category(%{title: "Elixir"})
    author = user("author")
    reader = user("reader")
    {:ok, thread} = Forums.create_thread(category, author, %{title: "OTP", body: "Cool?"})
    flush()

    %{category: category, author: author, reader: reader, thread: thread}
  end

  defp user(name) do
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  # Casts are async; a call to the server waits for them.
  defp flush, do: :sys.get_state(Notifications)

  defp reply(thread, user, body) do
    {:ok, post} = Forums.create_post(thread, user, %{body: body})
    flush()
    post
  end

  defp notifications(user), do: Forums.notifications_for(user)

  test "starting a thread watches it; replying tracks it", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    assert Subscriptions.thread_level(author, thread) == "watching"
    reply(thread, reader, "yup")
    assert Subscriptions.thread_level(reader, thread) == "tracking"

    # An explicit choice isn't overridden by replying
    {:ok, _} = Subscriptions.set_thread_level(author, thread, "muted")
    reply(thread, author, "me again")
    assert Subscriptions.thread_level(author, thread) == "muted"
  end

  test "watchers get a typed notification and an email; the poster doesn't", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    reply(thread, reader, "yup")

    assert [notification] = notifications(author)
    assert notification.kind == "new_post"
    assert notification.subject == ~s(@reader replied in "OTP")
    assert notification.emailed_at
    assert_email_delivered_with(to: [nil: "author@example.com"])

    assert notifications(reader) == []
  end

  test "trackers are notified in-app only", %{author: author, reader: reader, thread: thread} do
    reply(thread, reader, "yup")
    reply(thread, author, "thanks")

    assert [%{kind: "new_post", emailed_at: nil}] = notifications(reader)
    refute_email_delivered_with(to: [nil: "reader@example.com"])
  end

  test "normal and muted aren't notified", %{author: author, reader: reader, thread: thread} do
    for level <- ["normal", "muted"] do
      {:ok, _} = Subscriptions.set_thread_level(author, thread, level)
      reply(thread, reader, "hello #{level}")
      assert notifications(author) == []
    end
  end

  test "emails once per thread until the notifications are read", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    reply(thread, reader, "one")
    reply(thread, reader, "two")

    assert [second, first] = notifications(author)
    assert first.emailed_at
    refute second.emailed_at

    Forums.mark_thread_read(author, thread)
    reply(thread, reader, "three")
    assert [third | _] = notifications(author)
    assert third.emailed_at
  end

  test "no email with email notifications off or an unconfirmed address", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    {:ok, _} = Forums.update_preferences(author, %{email_notifications: false})
    reply(thread, reader, "one")
    assert [%{emailed_at: nil}] = notifications(author)
    assert_no_emails_delivered()
  end

  test "category watchers hear about new threads and their posts", %{
    category: category,
    author: author,
    reader: reader
  } do
    {:ok, _} = Subscriptions.set_category_level(reader, category, "watching")

    {:ok, thread} = Forums.create_thread(category, author, %{title: "Fresh", body: "Hi"})
    flush()
    assert [%{kind: "new_thread", subject: ~s(@author started "Fresh")}] = notifications(reader)

    reply(thread, author, "more")
    assert [%{kind: "new_post"} | _] = notifications(reader)

    # A thread-level choice overrides the category
    {:ok, _} = Subscriptions.set_thread_level(reader, thread, "normal")
    count = length(notifications(reader))
    reply(thread, author, "even more")
    assert length(notifications(reader)) == count
  end

  test "muted threads and categories drop out of the lists", %{
    category: category,
    author: author,
    reader: reader,
    thread: thread
  } do
    assert Enum.any?(Forums.latest_threads(reader), &(&1.id == thread.id))

    {:ok, _} = Subscriptions.set_thread_level(reader, thread, "muted")
    refute Enum.any?(Forums.latest_threads(reader), &(&1.id == thread.id))

    {:ok, other} = Forums.create_thread(category, author, %{title: "Other", body: "x"})
    {:ok, _} = Subscriptions.set_category_level(reader, category, "muted")
    refute Enum.any?(Forums.latest_threads(reader), &(&1.id == other.id))
    refute Enum.any?(Forums.new_threads(reader), &(&1.id == other.id))

    # Unmuting the thread itself brings it back despite the muted category
    {:ok, _} = Subscriptions.set_thread_level(reader, thread, "tracking")
    assert Enum.any?(Forums.latest_threads(reader), &(&1.id == thread.id))
  end

  test "reading a thread reads its notifications", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    reply(thread, reader, "yup")
    assert Forums.unread_notification_count(author) == 1
    Forums.mark_thread_read(author, thread)
    assert Forums.unread_notification_count(author) == 0
  end

  test "a reply deleted before it fans out notifies no one", %{
    author: author,
    reader: reader,
    thread: thread
  } do
    :sys.suspend(Notifications)
    {:ok, post} = Forums.create_post(thread, reader, %{body: "never mind"})
    {:ok, _} = Forums.delete_post(post, reader)
    :sys.resume(Notifications)
    flush()

    assert notifications(author) == []
    assert_no_emails_delivered()
  end
end
