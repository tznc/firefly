defmodule Firefly.NotificationSubjectTest do
  @moduledoc "Regression tests for notifications Firefly.NotificationsPropertyTest found mishandled."
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Discussion, Notifications}

  # Subjects quote thread titles (up to 255 characters): one past the
  # 255-character column raised, failing the like that made it.
  test "a like in a thread with a long title notifies, with the subject cut" do
    author = user_fixture()
    liker = user_fixture()
    category = category_fixture("Long")
    thread = thread_fixture(category, author, %{title: String.duplicate("t", 250)})
    [post] = Repo.all(from(p in Discussion.Post, where: p.thread_id == ^thread.id))

    assert :ok = Discussion.like_post(post, liker)

    assert [%{subject: subject}] =
             Notifications.notifications_for(author) |> Enum.filter(&(&1.kind == "liked"))

    assert String.length(subject) == 255
    assert String.ends_with?(subject, "…")
  end

  test "subjects are cut by code point, as Postgres counts them" do
    user = user_fixture()
    subject = String.duplicate("e\u0301", 200)

    assert {:ok, notification} =
             Notifications.notify(user, %{kind: "plugin", subject: subject, body: "B", url: "/"})

    assert length(String.codepoints(notification.subject)) == 255
  end
end
