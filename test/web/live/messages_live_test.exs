defmodule FirestormWeb.Web.MessagesLiveTest do
  use FirestormWeb.Web.ConnCase
  # Emails go to the test process (they're tested in MessagesTest).
  use Bamboo.Test, shared: true

  alias FirestormWeb.{Forums, Messages, Notifications}

  setup do
    {:ok, _} = Notifications.start_link()
    %{alice: user_fixture(%{username: "alice"}), bob: user_fixture(%{username: "bob"})}
  end

  defp flush, do: :sys.get_state(Notifications)

  defp start(sender, recipients, body \\ "Secret plans") do
    {:ok, conversation} =
      Messages.start_conversation(sender, %{
        "recipients" => recipients,
        "title" => "Hush",
        "body" => body
      })

    flush()
    conversation
  end

  test "messaging someone from their profile", %{conn: conn, alice: alice, bob: bob} do
    conn
    |> log_in_as(alice)
    |> visit(~p"/users/#{bob}")
    |> click_link("main a", "Message")
    |> assert_path(~p"/messages/new")
    |> assert_has("input[name='conversation[recipients]'][value='@bob']")
    |> fill_in("Title", with: "Lunch?")
    |> fill_in("Body", with: "Tomorrow at **noon**")
    |> click_button("Send")
    |> assert_has("#flash-info", text: "Message sent.")
    |> assert_has("h1", text: "Lunch?")
    |> assert_has("#participants", text: "@bob")
    |> assert_has("#messages strong", text: "noon")

    flush()

    conn
    |> log_in_as(bob)
    |> visit(~p"/")
    |> assert_has("#message-count", text: "1")
    |> click_link("Messages")
    |> assert_has("#conversations .unread", text: "Lunch?")
    |> assert_has("#conversations", text: "with @alice")
    |> click_link("Lunch?")
    |> refute_has("#message-count")
    |> fill_in("Body", with: "Sounds good")
    |> click_button("Reply")
    |> assert_has("#messages", text: "Sounds good")

    flush()
    assert [%{kind: "message"}] = Forums.notifications_for(alice)
  end

  test "form errors are shown", %{conn: conn, alice: alice} do
    conn
    |> log_in_as(alice)
    |> visit(~p"/messages/new")
    |> fill_in("To", with: "@nobody")
    |> fill_in("Title", with: "Hi")
    |> fill_in("Body", with: "Hello")
    |> click_button("Send")
    |> assert_has("#conversation-form", text: "no such user: @nobody")
  end

  test "users who turned messages off have no Message button", %{conn: conn, alice: alice} do
    {:ok, hermit} =
      Forums.update_preferences(user_fixture(%{username: "hermit"}), %{
        allow_private_messages: false
      })

    conn
    |> log_in_as(alice)
    |> visit(~p"/users/#{hermit}")
    |> refute_has("main a", text: "Message")
  end

  test "the preference is on the notification settings page", %{conn: conn, bob: bob} do
    conn
    |> log_in_as(bob)
    |> visit(~p"/settings/notifications")
    |> uncheck("Allow other members to send me private messages")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "Notification settings saved.")

    refute Forums.get_user!(bob.id).allow_private_messages
  end

  test "only participants can open a conversation", %{conn: conn, alice: alice} do
    conversation = start(alice, "bob")

    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/messages/#{conversation.id}")
    |> assert_path(~p"/messages")
    |> assert_has("#flash-error", text: "Conversation not found.")
    |> refute_has("#conversations", text: "Hush")

    conn |> visit(~p"/messages/#{conversation.id}") |> assert_path(~p"/categories")
  end

  test "the starter adds people; others don't get the form", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx
    carol = user_fixture(%{username: "carol"})
    conversation = start(alice, "bob")

    conn
    |> log_in_as(bob)
    |> visit(~p"/messages/#{conversation.id}")
    |> refute_has("#add-participants-form")

    conn
    |> log_in_as(alice)
    |> visit(~p"/messages/#{conversation.id}")
    |> fill_in("Add people", with: "@ghost")
    |> click_button("Add people")
    |> assert_has("#add-participants-form", text: "no such user: @ghost")
    |> fill_in("Add people", with: "@carol")
    |> click_button("Add people")
    |> assert_has("#flash-info", text: "Added @carol.")
    |> assert_has("#participants", text: "@carol")

    flush()
    assert [%{subject: ~s(@alice added you to "Hush")}] = Forums.notifications_for(carol)
  end

  test "leaving a conversation", %{conn: conn, alice: alice, bob: bob} do
    conversation = start(alice, "bob")

    conn
    |> log_in_as(bob)
    |> visit(~p"/messages/#{conversation.id}")
    |> click_button("Leave")
    |> assert_path(~p"/messages")
    |> assert_has("#flash-info", text: "You left the conversation.")
    |> refute_has("#conversations", text: "Hush")

    refute Messages.participant?(conversation, bob)
  end

  test "messages don't show up in public pages or the API", %{conn: conn, alice: alice} do
    thread = thread_fixture(category_fixture(), alice, %{title: "Public thread"})
    start(alice, "bob", "xylophone confidential")
    outsider = conn |> log_in_as(user_fixture())

    outsider
    |> visit(~p"/search?q=xylophone")
    |> refute_has("#search-results li")

    outsider |> visit(~p"/") |> refute_has("#threads", text: "Hush")

    outsider
    |> visit(~p"/users/#{alice}")
    |> refute_has("#user-posts", text: "xylophone")

    outsider
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}")
    |> refute_has("#posts", text: "xylophone")

    assert %{"results" => []} = conn |> get(~p"/api/v1/search?q=xylophone") |> json_response(200)
  end
end
