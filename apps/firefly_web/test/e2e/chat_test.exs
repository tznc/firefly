defmodule FireflyWeb.E2E.ChatTest do
  use FireflyWeb.E2ECase, async: false

  alias Firefly.Chat

  setup do
    admin = admin_fixture("root")
    {:ok, general} = Chat.create_channel(%{"name" => "General"}, admin)

    alice = member_fixture("alice")
    :ok = Chat.follow(general, alice)
    :ok = Chat.follow(general, member_fixture("bob"))

    %{path: "/chat/c/general/#{general.id}", general: general, alice: alice}
  end

  test "two members chat live; Enter sends, Shift+Enter doesn't",
       %{conn: conn, path: path} = context do
    alice =
      conn
      |> log_in("alice")
      |> visit(path)
      |> assert_has("[data-phx-main].phx-connected")
      |> assert_has("#channel-title", text: "General")

    bob =
      another_browser(context)
      |> log_in("bob")
      |> visit(path)
      |> assert_has("[data-phx-main].phx-connected")
      |> assert_has("#presence", text: "2 here")

    alice
    |> type("#chat-form-body", "Hello from **alice**")
    |> press("#chat-form-body", "Enter")
    |> assert_has("#chat-messages strong", text: "alice")

    # The other browser gets it without a reload, and answers.
    bob
    |> assert_has("#chat-messages article", text: "Hello from alice")
    |> type("#chat-form-body", "Hi alice")
    |> press("#chat-form-body", "Shift+Enter")
    |> type("#chat-form-body", "second line")
    |> click_button("#chat-form button", "Send")

    alice
    |> assert_has("#chat-messages article", text: "second line")
    |> assert_has("#chat-form-body", value: "")
  end

  test "a thread reply shows in the thread pane of the other browser",
       %{conn: conn, path: path} = context do
    alice =
      conn
      |> log_in("alice")
      |> visit(path)
      |> assert_has("[data-phx-main].phx-connected")
      |> type("#chat-form-body", "Lunch plans?")
      |> press("#chat-form-body", "Enter")
      |> assert_has("#chat-messages article", text: "Lunch plans?")

    [message] = Chat.messages(context.general, context.alice)

    alice
    |> visit("#{path}/t/#{message.id}")
    |> assert_has("[data-phx-main].phx-connected")
    |> assert_has("#chat-pane h2", text: "Thread")

    another_browser(context)
    |> log_in("bob")
    |> visit(path)
    |> assert_has("[data-phx-main].phx-connected")
    |> click_button("#chat-message-#{message.id} button[aria-label^='Actions']", "")
    |> click_link("#chat-message-#{message.id} a", "Reply in thread")
    |> assert_has("#chat-pane h2", text: "Thread")
    |> type("#chat-thread-form-body", "Tacos")
    |> press("#chat-thread-form-body", "Enter")
    |> assert_has("#thread-messages article", text: "Tacos")

    alice
    |> assert_has("#thread-messages article", text: "Tacos")
    |> assert_has("#chat-message-#{message.id} a", text: "1 reply")
    |> refute_has("#chat-messages article", text: "Tacos")
  end
end
