defmodule Firefly.ChatTest do
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Accounts, Backups, Chat, Discussion, Groups, Repo, SiteSettings, Uploads}
  alias Firefly.Accounts.Ignores
  alias Firefly.Chat.{Channel, Membership}
  alias Firefly.Moderation.{Penalties, StaffAction, WatchedWords}

  setup do
    admin = admin_fixture(%{username: "admin"})
    alice = member("alice")
    bob = member("bob")
    {:ok, general} = Chat.create_channel(%{"name" => "General"}, admin)
    %{admin: admin, alice: alice, bob: bob, general: general}
  end

  # A confirmed basic user (trust level 1: may start direct messages).
  defp member(username, level \\ 1) do
    user = user_fixture(%{username: username})
    {:ok, user} = Accounts.confirm_user(user)
    Repo.update!(Ecto.Changeset.change(user, trust_level: level))
  end

  defp send!(channel, user, body, attrs \\ %{}) do
    {:ok, message} = Chat.send_message(channel, user, Map.put(attrs, "body", body))
    message
  end

  defp entry(user, channel) do
    %{channels: channels, direct: direct} = Chat.my_channels(user)
    Enum.find(channels ++ direct, &(&1.channel.id == channel.id))
  end

  defp settings(admin, params), do: {:ok, _} = SiteSettings.update(params, admin)

  describe "channels" do
    test "staff create, rename and close channels, logged", ctx do
      assert %Channel{slug: "general", status: "open"} = ctx.general
      assert {:error, :unauthorized} = Chat.create_channel(%{"name" => "Mine"}, ctx.alice)

      {:error, changeset} = Chat.create_channel(%{"name" => "General"}, ctx.admin)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)

      {:ok, renamed} =
        Chat.update_channel(ctx.general, %{"name" => "Lobby", "slug" => "lobby"}, ctx.admin)

      {:ok, closed} = Chat.set_status(renamed, "closed", ctx.admin)
      assert closed.status == "closed"
      assert {:error, _changeset} = Chat.set_status(closed, "gone", ctx.admin)

      assert ~w(chat_channel.create chat_channel.update chat_channel.status) ==
               Repo.all(from(a in StaffAction, order_by: a.id, select: a.action))
    end

    test "members follow, leave, mute and set their notification level", ctx do
      assert [{%Channel{name: "General"}, false}] = Chat.browse_channels(ctx.alice)
      assert :ok = Chat.follow(ctx.general, ctx.alice)
      assert [{_channel, true}] = Chat.browse_channels(ctx.alice)
      assert %{channels: [%{channel: %{name: "General"}}]} = Chat.my_channels(ctx.alice)

      {:ok, membership} =
        Chat.update_membership(ctx.general, ctx.alice, %{
          "muted" => "true",
          "notification_level" => "always"
        })

      assert %Membership{muted: true, notification_level: "always"} = membership

      assert {:error, _changeset} =
               Chat.update_membership(ctx.general, ctx.alice, %{"notification_level" => "loud"})

      :ok = Chat.unfollow(ctx.general, ctx.alice)
      assert %{channels: []} = Chat.my_channels(ctx.alice)
    end

    test "archived channels leave the list of those who don't follow them", ctx do
      {:ok, _} = Chat.set_status(ctx.general, "archived", ctx.admin)
      assert Chat.browse_channels(ctx.alice) == []
      assert [{_channel, true}] = Chat.browse_channels(ctx.admin)
    end

    test "a category channel follows its category's read access", ctx do
      {:ok, team} = Groups.create_group(%{name: "team"}, ctx.admin)
      {:ok, _} = Groups.add_member(team, "alice", ctx.admin)
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})

      {:ok, channel} =
        Chat.create_channel(%{"name" => "Secret plans", "category_id" => secret.id}, ctx.admin)

      assert Chat.can?(ctx.alice, :view_channel, channel)
      refute Chat.can?(ctx.bob, :view_channel, channel)
      assert {:error, :unauthorized} = Chat.follow(channel, ctx.bob)
      assert {:error, :unauthorized} = Chat.send_message(channel, ctx.bob, %{"body" => "hi"})

      :ok = Chat.follow(channel, ctx.alice)
      send!(channel, ctx.alice, "psst")
      {:ok, _} = Groups.remove_member(team, ctx.alice, ctx.admin)

      # Losing access to the category loses the channel.
      refute entry(ctx.alice, channel)
      refute Chat.can?(ctx.alice, :view_channel, channel)
    end

    test "chat is for the allowed groups, while it's on", ctx do
      newbie = member("newbie", 0)
      assert Chat.can?(newbie, :use_chat)

      settings(ctx.admin, %{"chat_allowed_groups" => "trust_level_1"})
      refute Chat.can?(newbie, :use_chat)
      assert Chat.can?(ctx.alice, :use_chat)

      settings(ctx.admin, %{"chat_allowed_groups" => ""})
      refute Chat.can?(ctx.alice, :use_chat)
      assert Chat.can?(ctx.admin, :use_chat)

      settings(ctx.admin, %{"chat_allowed_groups" => "trust_level_0", "chat_enabled" => "false"})
      refute Chat.can?(ctx.admin, :use_chat)
      refute Chat.can?(ctx.alice, :view_channel, ctx.general)
    end
  end

  describe "direct messages" do
    test "the same people share one channel, shown to the others once there's a message", ctx do
      {:ok, dm} = Chat.direct_channel(ctx.alice, ["@bob"])
      assert {:ok, ^dm} = Chat.direct_channel(ctx.bob, ["alice"])
      assert dm.kind == "direct"
      assert Chat.title(dm, ctx.alice) == "@bob"

      refute Chat.can?(ctx.admin, :view_channel, dm)
      refute entry(ctx.alice, dm) == nil
      :ok = Chat.unfollow(dm, ctx.bob)
      refute entry(ctx.bob, dm)

      send!(dm, ctx.alice, "hello bob")
      assert %{unread: 1, membership: %{notification_level: "always"}} = entry(ctx.bob, dm)
    end

    test "starting one needs the direct message groups; who can be messaged", ctx do
      newbie = member("newbie", 0)
      assert {:error, :unauthorized} = Chat.direct_channel(newbie, ["alice"])

      assert {:error, "no such user: @nobody"} = Chat.direct_channel(ctx.alice, ["nobody"])
      assert {:error, "add at least one other person"} = Chat.direct_channel(ctx.alice, ["alice"])

      {:ok, _} = Ignores.set(ctx.bob, ctx.alice, "ignore")
      assert {:error, "@bob can't be messaged"} = Chat.direct_channel(ctx.alice, ["bob"])
      assert {:ok, _dm} = Chat.direct_channel(ctx.admin, ["bob"])

      settings(ctx.admin, %{"chat_max_direct_message_users" => "2"})
      carol = member("carol")

      assert {:error, "a direct message can have at most 2 people"} =
               Chat.direct_channel(ctx.alice, ["carol", "admin"])

      assert {:ok, _dm} = Chat.direct_channel(ctx.alice, [carol.username])
    end
  end

  describe "messages" do
    setup ctx do
      :ok = Chat.follow(ctx.general, ctx.alice)
      :ok = Chat.follow(ctx.general, ctx.bob)
      :ok
    end

    test "count as unread and mentions until read; live to subscribers", ctx do
      Chat.subscribe(ctx.general)
      first = send!(ctx.general, ctx.alice, "hello @bob")
      assert_receive {:message_created, %{id: id, user: %{username: "alice"}}}
      assert id == first.id
      send!(ctx.general, ctx.alice, "anyone?")

      assert %{unread: 2, mentions: 1} = entry(ctx.bob, ctx.general)
      assert %{unread: 0, mentions: 0} = entry(ctx.alice, ctx.general)
      assert Chat.unread_channel_count(ctx.bob) == 1

      Chat.subscribe_user(ctx.bob)
      :ok = Chat.mark_read(ctx.general, ctx.bob, first.id)
      assert_receive {:chat_read, _channel_id}
      assert %{unread: 1, mentions: 0} = entry(ctx.bob, ctx.general)

      :ok = Chat.mark_read(ctx.general, ctx.bob)
      assert %{unread: 0} = entry(ctx.bob, ctx.general)
      # Positions only move forward.
      :ok = Chat.mark_read(ctx.general, ctx.bob, first.id)
      assert Chat.last_read_message_id(ctx.general, ctx.bob) > first.id
    end

    test "page through the stream", ctx do
      ids = for n <- 1..5, do: send!(ctx.general, ctx.alice, "message #{n}").id

      assert Enum.map(Chat.messages(ctx.general, ctx.bob, limit: 2), & &1.id) ==
               Enum.take(ids, -2)

      assert Enum.map(
               Chat.messages(ctx.general, ctx.bob, before: Enum.at(ids, 3), limit: 2),
               & &1.id
             ) ==
               Enum.slice(ids, 1, 2)

      assert Enum.map(Chat.messages(ctx.general, ctx.bob, after: Enum.at(ids, 2)), & &1.id) ==
               Enum.take(ids, -2)
    end

    test "replies quote; thread replies stay out of the stream, with their own unread", ctx do
      question = send!(ctx.general, ctx.alice, "Thoughts?")
      quoted = send!(ctx.general, ctx.bob, "Yes", %{"in_reply_to_id" => question.id})
      assert quoted.in_reply_to.id == question.id

      reply = send!(ctx.general, ctx.bob, "In a thread", %{"thread_of" => question.id})
      assert reply.thread_id
      send!(ctx.general, ctx.bob, "More", %{"thread_of" => question.id})

      stream = Chat.messages(ctx.general, ctx.alice)
      assert Enum.map(stream, & &1.body) == ["Thoughts?", "Yes"]
      assert hd(stream).reply_count == 2

      thread = Chat.get_thread(reply.thread_id)

      assert Enum.map(Chat.thread_messages(thread, ctx.alice), & &1.body) ==
               ["Thoughts?", "In a thread", "More"]

      # The original message's author takes part; thread replies aren't
      # the stream's unread messages.
      assert Chat.thread_unread_counts(ctx.general, ctx.alice) == %{thread.id => 2}
      assert %{unread: 1} = entry(ctx.alice, ctx.general)
      :ok = Chat.mark_thread_read(thread, ctx.alice)
      assert Chat.thread_unread_counts(ctx.general, ctx.alice) == %{}

      assert {:error, :not_found} =
               Chat.send_message(ctx.general, ctx.bob, %{"body" => "x", "thread_of" => "999999"})
    end

    test "edits keep revisions; deletes and restores", ctx do
      message = send!(ctx.general, ctx.alice, "Helo")
      Chat.subscribe(ctx.general)

      assert {:error, :unauthorized} = Chat.edit_message(message, ctx.bob, %{"body" => "x"})
      {:ok, edited} = Chat.edit_message(message, ctx.alice, %{"body" => "Hello @bob"})
      assert edited.edited_at
      assert_receive {:message_updated, %{body: "Hello @bob"}}
      assert [%{body: "Helo", user: %{username: "alice"}}] = Chat.revisions(message)
      assert %{mentions: 1} = entry(ctx.bob, ctx.general)

      assert {:error, :unauthorized} = Chat.delete_message(message, ctx.bob)
      {:ok, deleted} = Chat.delete_message(message, ctx.alice)
      assert deleted.deleted_at
      assert %{unread: 0, mentions: 0} = entry(ctx.bob, ctx.general)
      {:ok, _} = Chat.restore_message(deleted, ctx.alice)

      # Staff deleting someone else's message is logged; only staff may
      # restore what staff deleted.
      {:ok, deleted} = Chat.delete_message(message, ctx.admin)
      assert {:error, :unauthorized} = Chat.restore_message(deleted, ctx.alice)
      {:ok, _} = Chat.restore_message(deleted, ctx.admin)

      assert ~w(chat_message.delete chat_message.restore) ==
               Repo.all(
                 from(a in StaffAction,
                   where: a.target_type == "chat_message",
                   order_by: a.id,
                   select: a.action
                 )
               )
    end

    test "closed channels take only staff messages; read-only ones none", ctx do
      {:ok, closed} = Chat.set_status(ctx.general, "closed", ctx.admin)
      assert {:error, :unauthorized} = Chat.send_message(closed, ctx.alice, %{"body" => "hi"})
      assert {:ok, _} = Chat.send_message(closed, ctx.admin, %{"body" => "staff only"})

      {:ok, read_only} = Chat.set_status(closed, "read_only", ctx.admin)
      assert {:error, :unauthorized} = Chat.send_message(read_only, ctx.admin, %{"body" => "hi"})
    end

    test "the posting gate: penalties, read-only mode, the chat rate limit", ctx do
      {:ok, _} =
        Penalties.penalize(:silence, ctx.alice, ctx.admin, %{
          "duration" => "1d",
          "reason" => "shh"
        })

      assert {:error, {:silenced, _}} =
               Chat.send_message(ctx.general, ctx.alice, %{"body" => "hi"})

      Backups.set_read_only("Maintenance", ctx.admin)
      on_exit(fn -> Backups.set_read_only(nil) end)
      assert {:error, :read_only} = Chat.send_message(ctx.general, ctx.bob, %{"body" => "hi"})
      Backups.set_read_only(nil)

      config = Application.get_env(:firefly, Firefly.RateLimit)
      limits = Keyword.put(config[:limits], :chat, {1, 60_000})
      Application.put_env(:firefly, Firefly.RateLimit, Keyword.put(config, :limits, limits))
      on_exit(fn -> Application.put_env(:firefly, Firefly.RateLimit, config) end)
      assert {:ok, _} = Chat.send_message(ctx.general, ctx.bob, %{"body" => "one"})
      assert {:error, :rate_limited} = Chat.send_message(ctx.general, ctx.bob, %{"body" => "two"})
    end

    test "watched words block or silence; validation", ctx do
      {:ok, _} = WatchedWords.create(ctx.admin, %{"word" => "darn", "action" => "block"})
      {:ok, _} = WatchedWords.create(ctx.admin, %{"word" => "spamz", "action" => "silence"})

      {:error, changeset} = Chat.send_message(ctx.general, ctx.alice, %{"body" => "darn it"})
      assert %{body: ["contains a word that's not allowed: darn"]} = errors_on(changeset)

      {:error, changeset} = Chat.send_message(ctx.general, ctx.alice, %{"body" => "  "})
      assert %{body: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, _} = Chat.send_message(ctx.general, ctx.alice, %{"body" => "buy spamz"})
      assert Accounts.User.silenced?(Repo.reload(ctx.alice))
    end

    test "messages from ignored users are left out", ctx do
      send!(ctx.general, ctx.alice, "from alice")
      {:ok, _} = Ignores.set(ctx.bob, ctx.alice, "ignore")
      assert Chat.messages(ctx.general, ctx.bob) == []
      assert %{unread: 0} = entry(ctx.bob, ctx.general)
    end

    @tag :tmp_dir
    test "uploads in messages are for those who may read the channel", ctx do
      path = Firefly.UploadHelpers.file(ctx.tmp_dir, "notes.txt", "hello")
      {:ok, upload} = Uploads.create(ctx.alice, path, "notes.txt")

      send!(ctx.general, ctx.alice, Uploads.markdown(upload))
      upload = Repo.reload(upload)
      assert upload.attached_to == "chat"
      assert Uploads.readable?(upload, ctx.bob)
      refute Uploads.readable?(upload, nil)
    end

    test "reactions toggle per user and emoji", ctx do
      message = send!(ctx.general, ctx.alice, "Ship it")
      {:ok, _} = Chat.toggle_reaction(message, ctx.bob, "👍")
      {:ok, _} = Chat.toggle_reaction(message, ctx.alice, "👍")
      {:ok, reacted} = Chat.toggle_reaction(message, ctx.bob, "🎉")

      assert [%{emoji: "👍", users: ["bob", "alice"]}, %{emoji: "🎉", users: ["bob"]}] =
               Chat.reaction_groups(reacted)

      {:ok, toggled} = Chat.toggle_reaction(message, ctx.bob, "👍")
      assert [%{emoji: "👍", users: ["alice"]}, _] = Chat.reaction_groups(toggled)

      assert {:error, :invalid_emoji} = Chat.toggle_reaction(message, ctx.bob, "<b>")
      assert {:error, :invalid_emoji} = Chat.toggle_reaction(message, ctx.bob, ":nope:")
    end

    test "pins: staff in category channels, members in direct messages", ctx do
      message = send!(ctx.general, ctx.alice, "Rules: be nice")
      assert {:error, :unauthorized} = Chat.pin_message(message, ctx.alice)
      {:ok, pinned} = Chat.pin_message(message, ctx.admin)
      assert pinned.pinned_at
      assert [%{id: id}] = Chat.pinned_messages(ctx.general, ctx.bob)
      assert id == message.id
      {:ok, _} = Chat.unpin_message(message, ctx.admin)
      assert Chat.pinned_messages(ctx.general, ctx.bob) == []

      {:ok, dm} = Chat.direct_channel(ctx.alice, ["bob"])
      note = send!(dm, ctx.alice, "the address")
      assert {:ok, _} = Chat.pin_message(note, ctx.bob)

      assert ~w(chat_message.pin chat_message.unpin) ==
               Repo.all(
                 from(a in StaffAction,
                   where: a.action in ["chat_message.pin", "chat_message.unpin"],
                   order_by: a.id,
                   select: a.action
                 )
               )
    end

    test "search finds what the user may read", ctx do
      {:ok, team} = Groups.create_group(%{name: "team"}, ctx.admin)
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})

      {:ok, hidden} =
        Chat.create_channel(%{"name" => "Hidden", "category_id" => secret.id}, ctx.admin)

      send!(ctx.general, ctx.alice, "launching rockets tomorrow")
      send!(hidden, ctx.admin, "rockets are secret")
      {:ok, dm} = Chat.direct_channel(ctx.admin, ["alice"])
      send!(dm, ctx.admin, "private rockets")
      gone = send!(ctx.general, ctx.alice, "deleted rockets")
      {:ok, _} = Chat.delete_message(gone, ctx.alice)

      assert ["launching rockets tomorrow"] = Enum.map(Chat.search(ctx.bob, "rocket"), & &1.body)

      assert ["private rockets", "launching rockets tomorrow"] =
               Enum.map(Chat.search(ctx.alice, "rockets"), & &1.body)

      assert [] = Chat.search(ctx.alice, "rockets", channel: hidden)
      assert Chat.search(ctx.alice, "  ") == []
    end

    test "threads list and paging around a message", ctx do
      ids = for n <- 1..60, do: send!(ctx.general, ctx.alice, "m#{n}").id
      around = Chat.messages(ctx.general, ctx.bob, around: Enum.at(ids, 10))
      assert Enum.at(ids, 10) in Enum.map(around, & &1.id)
      assert length(around) == 36

      send!(ctx.general, ctx.bob, "reply", %{"thread_of" => hd(ids)})

      assert [%{original: %{id: original_id, reply_count: 1}, unread: 1}] =
               Chat.threads(ctx.general, ctx.alice)

      assert original_id == hd(ids)
    end
  end
end
