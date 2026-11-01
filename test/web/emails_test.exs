defmodule FirestormWeb.EmailsTest do
  use FirestormWeb.DataCase

  alias FirestormWeb.{Emails, Forums, ReplyAddress}

  test "notification emails come from Firefly with a signed per-user reply address" do
    {:ok, user} = Forums.create_user(%{username: "u", name: "U", email: "u@example.com"})
    {:ok, category} = Forums.create_category(%{title: "Elixir"})
    {:ok, thread} = Forums.create_thread(category, user, %{title: "T", body: "B"})
    [post] = Repo.preload(thread, :posts).posts

    email = Emails.thread_new_post_notification(user, thread, post)

    assert email.from == {"Firefly", "noreply@firefly.tznc.dev"}
    assert email.headers["reply-to"] == ReplyAddress.address(thread, user)
    assert email.html_body =~ "/categories/#{category.id}/threads/#{thread.id}"
    assert {:ok, thread_id, user_id} = ReplyAddress.verify(email.headers["reply-to"])
    assert {thread_id, user_id} == {thread.id, user.id}
  end
end
