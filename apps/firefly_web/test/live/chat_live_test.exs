defmodule FireflyWeb.ChatLiveTest do
  use FireflyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Firefly.{Chat, Repo}

  setup do
    admin = admin_fixture(%{username: "admin"})
    alice = member("alice")
    bob = member("bob")
    {:ok, general} = Chat.create_channel(%{"name" => "General"}, admin)
    :ok = Chat.follow(general, alice)
    :ok = Chat.follow(general, bob)
    %{admin: admin, alice: alice, bob: bob, general: general}
  end

  defp member(username) do
    user = user_fixture(%{username: username})
    Repo.update!(Ecto.Changeset.change(user, trust_level: 1))
  end

  defp open(conn, user, path) do
    {:ok, view, _html} = conn |> log_in_as(user) |> live(path)
    view
  end

  defp path(channel), do: ~p"/chat/c/#{channel.slug || "dm"}/#{channel.id}"

  defp send_body(view, body, form \\ "#chat-form", as \\ :message) do
    view |> form(form, %{as => %{body: body}}) |> render_submit()
  end

  test "the sidebar shows followed channels with unread and mention counts", ctx do
    {:ok, _} = Chat.send_message(ctx.general, ctx.alice, %{"body" => "hi @bob"})
    {:ok, _} = Chat.send_message(ctx.general, ctx.alice, %{"body" => "anyone?"})

    view = open(ctx.conn, ctx.bob, ~p"/chat")
    assert has_element?(view, "#sidebar-channel-#{ctx.general.id}", "General")
    assert has_element?(view, "#sidebar-channel-#{ctx.general.id} [aria-label='1 mentions']")

    # Opening the channel reads it, with a divider at the first unread one.
    view |> element("#sidebar-channel-#{ctx.general.id} a") |> render_click()
    assert has_element?(view, "#new-messages-divider")
    assert has_element?(view, "#chat-messages", "anyone?")
    refute has_element?(view, "#sidebar-channel-#{ctx.general.id} .badge")
  end

  test "messages arrive live; edit, delete, reactions and pins", ctx do
    alice_view = open(ctx.conn, ctx.alice, path(ctx.general))
    bob_view = open(build_conn(), ctx.bob, path(ctx.general))

    send_body(alice_view, "Hello **world**")
    [message] = Chat.messages(ctx.general, ctx.alice)
    assert has_element?(bob_view, "#chat-message-#{message.id} strong", "world")
    assert has_element?(bob_view, "#presence", "2 here")

    alice_view |> element("#chat-message-#{message.id} button", "Edit") |> render_click()

    alice_view
    |> form("#chat-edit-#{message.id}-false", %{edit: %{body: "Hello there"}})
    |> render_submit()

    assert has_element?(bob_view, "#chat-message-#{message.id}", "Hello there")
    assert has_element?(bob_view, "#chat-message-#{message.id}", "(edited)")

    bob_view
    |> element("#chat-message-#{message.id} button[aria-label='React 👍']")
    |> render_click()

    assert has_element?(alice_view, "#chat-message-#{message.id} button[aria-label='👍 1']")

    # Members can't pin in a category channel; staff can.
    refute has_element?(bob_view, "#chat-message-#{message.id} button", "Pin")
    {:ok, _} = Chat.pin_message(message, ctx.admin)
    bob_view |> element("button[aria-label='Pinned']") |> render_click()
    assert has_element?(bob_view, "#pinned-#{message.id}")

    alice_view |> element("#chat-message-#{message.id} button", "Delete") |> render_click()
    assert has_element?(bob_view, "#chat-message-#{message.id}", "This message was deleted.")
    assert has_element?(alice_view, "#chat-message-#{message.id} button", "Restore")
  end

  test "quote replies and threads", ctx do
    {:ok, question} = Chat.send_message(ctx.general, ctx.alice, %{"body" => "Thoughts?"})
    view = open(ctx.conn, ctx.bob, path(ctx.general))

    view |> element("#chat-message-#{question.id} button", "Quote reply") |> render_click()
    assert has_element?(view, "#replying-to", "Thoughts?")
    send_body(view, "Agreed")
    assert has_element?(view, "#chat-messages blockquote", "Thoughts?")
    refute has_element?(view, "#replying-to")

    view |> element("#chat-message-#{question.id} a", "Reply in thread") |> render_click()
    assert_patch(view, ~p"/chat/c/general/#{ctx.general.id}/t/#{question.id}")
    send_body(view, "In the thread", "#chat-thread-form", :thread_message)

    assert has_element?(view, "#thread-messages", "In the thread")
    refute has_element?(view, "#chat-messages", "In the thread")
    assert has_element?(view, "#chat-message-#{question.id} a", "1 reply")
  end

  test "penalties and closed channels are refused with a message", ctx do
    {:ok, _} =
      Firefly.Moderation.Penalties.penalize(:silence, ctx.alice, ctx.admin, %{
        "duration" => "1d",
        "reason" => "shh"
      })

    view = open(ctx.conn, ctx.alice, path(ctx.general))
    assert send_body(view, "hi") =~ "You&#39;ve been silenced"

    {:ok, _} = Chat.set_status(ctx.general, "closed", ctx.admin)
    assert has_element?(view, "#channel-closed", "only staff can post")
  end

  test "browsing, following and staff creating channels", ctx do
    carol = member("carol")
    view = open(ctx.conn, carol, ~p"/chat")
    assert has_element?(view, "#browse-channel-#{ctx.general.id}", "General")
    refute has_element?(view, "#new-channel-form")
    view |> element("#browse-channel-#{ctx.general.id} button", "Follow") |> render_click()
    assert has_element?(view, "#sidebar-channel-#{ctx.general.id}")

    admin_view = open(build_conn(), ctx.admin, ~p"/chat")

    admin_view
    |> form("#new-channel-form", %{channel: %{name: "Off topic", description: "Anything goes"}})
    |> render_submit()

    assert_patch(
      admin_view,
      ~p"/chat/c/off-topic/#{Repo.get_by!(Firefly.Chat.Channel, slug: "off-topic").id}"
    )

    admin_view |> element("button[aria-label='Settings']") |> render_click()
    admin_view |> element("button", "Archive") |> render_click()
    assert has_element?(admin_view, "#channel-status", "archived")
  end

  test "direct messages", ctx do
    view = open(ctx.conn, ctx.alice, ~p"/chat/new-message")
    view |> form("#new-dm-form", %{dm: %{usernames: "@nobody"}}) |> render_submit()
    assert has_element?(view, "#new-dm-form", "no such user: @nobody")

    view |> form("#new-dm-form", %{dm: %{usernames: "@bob"}}) |> render_submit()
    {:ok, dm} = Chat.direct_channel(ctx.alice, ["bob"])
    assert_patch(view, path(dm))
    assert has_element?(view, "#channel-title", "@bob")
    send_body(view, "psst")

    bob_view = open(build_conn(), ctx.bob, ~p"/chat")
    assert has_element?(bob_view, "#sidebar-channel-#{dm.id}", "@alice")
  end

  test "search finds the messages one may read", ctx do
    {:ok, message} =
      Chat.send_message(ctx.general, ctx.alice, %{"body" => "deploying the rocket"})

    view = open(ctx.conn, ctx.bob, path(ctx.general))
    view |> element("button[aria-label='Search']") |> render_click()
    view |> form("#chat-search-form", %{q: "rocket"}) |> render_submit()
    assert has_element?(view, "#search-result-#{message.id}", "deploying the rocket")
  end

  test "chat needs the allowed groups", ctx do
    {:ok, _} = Firefly.SiteSettings.update(%{"chat_allowed_groups" => "staff_only"}, ctx.admin)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             ctx.conn |> log_in_as(ctx.alice) |> live(~p"/chat")
  end
end
