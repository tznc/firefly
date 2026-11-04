defmodule Firefly.IgnoresTest do
  use Firefly.DataCase
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  alias Firefly.{Accounts, Discussion, Groups, Messaging, Notifications}
  alias Firefly.Accounts.{AccountDeletion, AccountExport, Ignores}
  alias Firefly.Accounts.UserIgnore

  setup do
    {:ok, _} = Notifications.start_link()
    category = category()
    %{alice: user("alice"), bob: user("bob"), category: category}
  end

  defp user(name) do
    {:ok, user} =
      Accounts.create_user(%{username: name, name: name, email: "#{name}@example.com"})

    user
  end

  defp category do
    {:ok, category} = Discussion.create_category(%{title: "Elixir"})
    category
  end

  defp flush, do: :sys.get_state(Notifications)

  defp thread(category, user, title \\ "OTP") do
    {:ok, thread} = Discussion.create_thread(category, user, %{title: title, body: "Cool?"})
    flush()
    thread
  end

  defp kinds(user), do: user |> Notifications.notifications_for() |> Enum.map(& &1.kind)

  describe "set/4" do
    test "mutes, ignores and changes its mind", %{alice: alice, bob: bob} do
      assert Ignores.level(alice, bob) == nil
      {:ok, _} = Ignores.set(alice, bob, "mute")
      assert Ignores.level(alice, bob) == "mute"
      assert Ignores.ignored_ids(alice) == []

      {:ok, _} = Ignores.set(alice, bob, "ignore", "1w")
      assert Ignores.level(alice, bob) == "ignore"
      assert Ignores.ignored_ids(alice) == [bob.id]
      assert [%{level: "ignore", expires_at: %DateTime{}}] = Ignores.list(alice)

      :ok = Ignores.remove(alice, bob)
      assert Ignores.level(alice, bob) == nil
    end

    test "staff and yourself can't be ignored", %{alice: alice} do
      {:ok, role} = Groups.create_role("admin")
      admin = user("admin")
      {:ok, _} = Groups.add_role(admin, role)

      assert Ignores.set(alice, admin, "ignore") == {:error, :staff}
      assert Ignores.set(alice, alice, "mute") == {:error, :self}
    end

    test "an expired ignore no longer applies", %{alice: alice, bob: bob} do
      {:ok, ignore} = Ignores.set(alice, bob, "ignore", "1d")

      Repo.update_all(from(i in UserIgnore, where: i.id == ^ignore.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert Ignores.level(alice, bob) == nil
      assert Ignores.ignored_ids(alice) == []
      assert Ignores.list(alice) == []
    end
  end

  describe "muting" do
    test "suppresses notifications from the muted user", %{
      alice: alice,
      bob: bob,
      category: category
    } do
      thread = thread(category, alice)
      {:ok, _} = Ignores.set(alice, bob, "mute")

      {:ok, post} = Discussion.create_post(thread, bob, %{body: "Hey @alice"})
      flush()
      [first_post] = Repo.preload(thread, :posts).posts
      Discussion.like_post(first_post, bob)

      assert kinds(alice) == []

      subject = Firefly.Notifications.Emails.mention_notification(alice, thread, post).subject
      refute_received {:email, %{subject: ^subject}}

      # Others still notify.
      carol = user("carol")
      {:ok, _} = Discussion.create_post(thread, carol, %{body: "Me too"})
      flush()
      assert kinds(alice) == ["new_post"]
    end

    test "blocks private messages from the muted user", %{alice: alice, bob: bob} do
      {:ok, _} = Ignores.set(alice, bob, "mute")

      assert {:error, changeset} =
               Messaging.start_conversation(bob, %{
                 "recipients" => "alice",
                 "title" => "Hi",
                 "body" => "Listen"
               })

      assert errors_on(changeset).recipients == ["@alice doesn't accept private messages"]
    end

    test "messages in a conversation from before don't notify", %{alice: alice, bob: bob} do
      {:ok, conversation} =
        Messaging.start_conversation(alice, %{
          "recipients" => "bob",
          "title" => "Hi",
          "body" => "x"
        })

      flush()
      {:ok, _} = Ignores.set(alice, bob, "mute")
      {:ok, _} = Messaging.reply(conversation, bob, %{body: "Answer"})
      flush()
      assert kinds(alice) == []
    end
  end

  describe "ignoring" do
    test "hides the user's threads from lists", %{alice: alice, bob: bob, category: category} do
      thread(category, alice, "Mine")
      theirs = thread(category, bob, "Theirs")
      {:ok, _} = Ignores.set(alice, bob, "ignore")

      titles = &Enum.map(&1, fn thread -> thread.title end)

      assert titles.(Discussion.latest_threads(alice)) == ["Mine"]
      assert titles.(Discussion.list_threads(category, alice)) == ["Mine"]
      assert titles.(Discussion.top_threads("all", alice)) == ["Mine"]
      assert "Theirs" in titles.(Discussion.latest_threads(bob))

      # A reply from them doesn't hide someone else's thread.
      {:ok, _} = Discussion.create_post(theirs, alice, %{body: "hm"})
      mine = Enum.find(Discussion.latest_threads(bob), &(&1.title == "Mine"))
      {:ok, _} = Discussion.create_post(mine, bob, %{body: "reply"})
      assert titles.(Discussion.latest_threads(alice)) == ["Mine"]
    end

    test "hides conversations they started from the inbox", %{alice: alice, bob: bob} do
      {:ok, _} =
        Messaging.start_conversation(bob, %{
          "recipients" => "alice",
          "title" => "Hi",
          "body" => "x"
        })

      flush()
      assert Messaging.unread_conversation_count(alice) == 1
      {:ok, _} = Ignores.set(alice, bob, "ignore")

      assert Messaging.inbox(alice, 1).entries == []
      assert Messaging.unread_conversation_count(alice) == 0
    end
  end

  test "export and account deletion", %{alice: alice, bob: bob} do
    {:ok, _} = Ignores.set(alice, bob, "mute")
    assert [%{username: "bob", level: "mute"}] = AccountExport.build(alice).muted_and_ignored

    {:ok, _} = AccountDeletion.delete_account(alice, "alice")
    assert Repo.aggregate(UserIgnore, :count) == 0
  end
end
