defmodule Firefly.ChatNotificationsTest do
  use Firefly.DataCase
  import Firefly.Fixtures

  alias Firefly.{Accounts, Chat, Groups, Notifications, Repo, SiteSettings, Webhooks}
  alias Firefly.Accounts.{AccountExport, AccountDeletion, Ignores}
  alias Firefly.Chat.{Flag, Membership, Message}
  alias Firefly.Moderation.{Review, StaffAction, WatchedWords}
  alias Firefly.Notifications.Notification
  alias Firefly.Webhooks.Delivery

  setup do
    admin = admin_fixture(%{username: "admin"})
    alice = member("alice")
    bob = member("bob")
    carol = member("carol")
    {:ok, general} = Chat.create_channel(%{"name" => "General"}, admin)
    for user <- [alice, bob, carol], do: :ok = Chat.follow(general, user)
    %{admin: admin, alice: alice, bob: bob, carol: carol, general: general}
  end

  defp member(username) do
    user = user_fixture(%{username: username})
    {:ok, user} = Accounts.confirm_user(user)
    Repo.update!(Ecto.Changeset.change(user, trust_level: 1))
  end

  defp flush, do: run_notifications()

  defp send!(channel, user, body, attrs \\ %{}) do
    {:ok, message} = Chat.send_message(channel, user, Map.put(attrs, "body", body))
    flush()
    message
  end

  defp kinds(user) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^user.id and n.kind in ["chat_mention", "chat_message"],
        order_by: n.id,
        select: n.kind
      )
    )
  end

  defp seen_now(user),
    do: Repo.update!(Ecto.Changeset.change(user, last_seen_at: DateTime.utc_now(:second)))

  describe "notifications" do
    test "mentions notify (and email the away); reading the channel reads them", ctx do
      seen_now(ctx.carol)
      send!(ctx.general, ctx.alice, "hey @bob and @carol")

      assert kinds(ctx.bob) == ["chat_mention"]
      assert kinds(ctx.carol) == ["chat_mention"]
      assert kinds(ctx.admin) == []

      [notification] = Notifications.notifications_for(ctx.bob)
      assert notification.subject == "@alice mentioned you in #General"
      assert Notification.path(notification) =~ ~r"^/chat/c/general/\d+\?message=\d+$"

      # Bob was away (never seen); Carol was here.
      assert_received {:email, %{subject: "@alice mentioned you in #General" <> _}}
      assert [%{emailed_at: %DateTime{}}] = Notifications.notifications_for(ctx.bob)

      assert [%{emailed_at: nil}] = Notifications.notifications_for(ctx.carol)

      :ok = Chat.mark_read(ctx.general, ctx.bob)
      assert Notifications.unread_notification_count(ctx.bob) == 0
    end

    test "direct messages notify every message, once per channel while unread", ctx do
      {:ok, dm} = Chat.direct_channel(ctx.alice, ["bob"])
      send!(dm, ctx.alice, "one")
      send!(dm, ctx.alice, "two")

      assert kinds(ctx.bob) == ["chat_message"]
      [notification] = Notifications.notifications_for(ctx.bob)
      assert notification.subject == "@alice sent you a direct message"
      assert notification.body == "Open chat to read it."
    end

    test "levels, mutes, ignores and reading decide who hears", ctx do
      {:ok, _} = Chat.update_membership(ctx.general, ctx.bob, %{"notification_level" => "always"})

      {:ok, _} =
        Chat.update_membership(ctx.general, ctx.carol, %{"notification_level" => "never"})

      send!(ctx.general, ctx.alice, "hello @carol")
      assert kinds(ctx.bob) == ["chat_message"]
      assert kinds(ctx.carol) == []

      {:ok, _} = Ignores.set(ctx.bob, ctx.alice, "mute")

      {:ok, _} =
        Chat.update_membership(ctx.general, ctx.carol, %{
          "notification_level" => "mention",
          "muted" => "true"
        })

      send!(ctx.general, ctx.alice, "again @bob @carol")
      assert kinds(ctx.bob) == ["chat_message"]
      assert kinds(ctx.carol) == []
    end

    test "@group, @all and @here, as allowed", ctx do
      {:ok, team} = Groups.create_group(%{name: "team"}, ctx.admin)
      {:ok, team} = Groups.update_settings(team, %{mentionable: "everyone"}, ctx.admin)
      {:ok, _} = Groups.add_member(team, "bob", ctx.admin)
      send!(ctx.general, ctx.alice, "ping @team")
      assert kinds(ctx.bob) == ["chat_mention"]
      assert kinds(ctx.carol) == []

      seen_now(ctx.carol)
      send!(ctx.general, ctx.alice, "@here look")
      assert kinds(ctx.carol) == ["chat_mention"]
      assert kinds(ctx.bob) == ["chat_mention"]

      send!(ctx.general, ctx.alice, "@all look")
      assert kinds(ctx.bob) == ["chat_mention", "chat_mention"]

      # Below the trust level, or where the channel doesn't allow them, they
      # mention nobody.
      {:ok, _} = SiteSettings.update(%{"chat_channel_wide_mentions_min_trust" => "2"}, ctx.admin)
      send!(ctx.general, ctx.alice, "@all again")
      assert length(kinds(ctx.bob)) == 2
    end
  end

  describe "moderation" do
    test "flags go to the review queue; staff agree (deleting) or disagree, logged", ctx do
      message = send!(ctx.general, ctx.alice, "rude words")

      assert {:error, :unauthorized} =
               Chat.flag_message(message, ctx.alice, %{"reason" => "spam"})

      {:ok, _} = Chat.flag_message(message, ctx.bob, %{"reason" => "inappropriate"})

      assert {:error, :already_flagged} =
               Chat.flag_message(message, ctx.bob, %{"reason" => "spam"})

      {:ok, _} = Chat.flag_message(message, ctx.carol, %{"reason" => "spam"})

      assert Review.pending_count() == 1
      assert [%{id: id, flags: [_, _]}] = Chat.flagged_messages()
      assert id == message.id

      assert {:error, :unauthorized} = Chat.review_flags(message, ctx.bob, :agree)
      {:ok, deleted} = Chat.review_flags(message, ctx.admin, :agree)
      assert deleted.deleted_at
      assert Review.pending_count() == 0
      assert {:error, :no_pending_flags} = Chat.review_flags(message, ctx.admin, :disagree)

      other = send!(ctx.general, ctx.alice, "fine words")
      {:ok, _} = Chat.flag_message(other, ctx.bob, %{"reason" => "off_topic"})
      {:ok, kept} = Chat.review_flags(other, ctx.admin, :disagree)
      refute kept.deleted_at

      assert ~w(chat_flag.agree chat_flag.disagree) ==
               Repo.all(
                 from(a in StaffAction,
                   where: a.action in ["chat_flag.agree", "chat_flag.disagree"],
                   order_by: a.id,
                   select: a.action
                 )
               )
    end

    test "a flag watched word flags the message for staff", ctx do
      on_exit(fn -> WatchedWords.put_cache(%{}) end)
      {:ok, _} = WatchedWords.create(ctx.admin, %{"word" => "crypto", "action" => "flag"})
      message = send!(ctx.general, ctx.alice, "buy crypto")

      assert [%Flag{user_id: nil, note: "Watched words: crypto"}] =
               Repo.all(from(f in Flag, where: f.message_id == ^message.id))
    end

    test "staff remove members (logged)", ctx do
      assert {:error, :unauthorized} = Chat.remove_member(ctx.general, ctx.bob, ctx.alice)
      :ok = Chat.remove_member(ctx.general, ctx.bob, ctx.admin)
      refute Chat.membership(ctx.general, ctx.bob)
      assert Repo.exists?(from(a in StaffAction, where: a.action == "chat_channel.remove_member"))
    end

    test "retention deletes old messages by channel kind", ctx do
      {:ok, dm} = Chat.direct_channel(ctx.alice, ["bob"])
      old = send!(ctx.general, ctx.alice, "old news")
      old_dm = send!(dm, ctx.alice, "old secret")
      fresh = send!(ctx.general, ctx.alice, "fresh")

      ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -10, :day)

      Repo.update_all(from(m in Message, where: m.id in ^[old.id, old_dm.id]),
        set: [inserted_at: ago]
      )

      {:ok, _} = SiteSettings.update(%{"chat_channel_retention_days" => "7"}, ctx.admin)
      :ok = Chat.run_due()
      refute Repo.get(Message, old.id)
      assert Repo.get(Message, old_dm.id)
      assert Repo.get(Message, fresh.id)
    end
  end

  describe "accounts" do
    test "export and deletion", ctx do
      message = send!(ctx.general, ctx.alice, "my words")
      {:ok, _} = Chat.toggle_reaction(message, ctx.alice, "🎉")

      assert %{
               messages: [%{body: "my words", channel: "General"}],
               channels: [%{channel: "General", following: true}],
               reactions: [%{emoji: "🎉"}]
             } = AccountExport.build(ctx.alice).chat

      {:ok, _} = AccountDeletion.delete_account(ctx.alice, "alice")
      refute Repo.exists?(from(m in Membership, where: m.user_id == ^ctx.alice.id))
      assert Repo.get(Message, message.id)
    end
  end

  test "plugin events and webhooks", ctx do
    {:ok, hook} =
      Webhooks.create(
        %{"payload_url" => "http://127.0.0.1:9/hook", "event_types" => ["chat"]},
        ctx.admin
      )

    {:ok, channel} = Chat.create_channel(%{"name" => "News"}, ctx.admin)
    message = send!(channel, ctx.admin, "hello")
    {:ok, _} = Chat.edit_message(message, ctx.admin, %{"body" => "hello!"})
    {:ok, _} = Chat.delete_message(message, ctx.admin)

    assert ~w(chat_channel_created chat_message_created chat_message_edited chat_message_deleted) ==
             Repo.all(
               from(d in Delivery,
                 where: d.webhook_id == ^hook.id,
                 order_by: d.id,
                 select: d.event
               )
             )
  end
end
