defmodule Firefly.MessagesTest do
  use Firefly.DataCase
  use Bamboo.Test, shared: true

  require Ecto.Query

  alias Firefly.{Accounts, Discussion, Groups, Messaging, Notifications, RateLimit}
  alias Firefly.Discussion.Search
  alias Firefly.Moderation.Posting
  alias Firefly.Discussion.Policy

  setup do
    {:ok, _} = Notifications.start_link()
    %{alice: user("alice"), bob: user("bob"), carol: user("carol")}
  end

  defp user(name, attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{username: name, name: name, email: "#{name}@example.com"})
      |> Accounts.create_user()

    user
  end

  # Casts are async; a call to the server waits for them.
  defp flush, do: :sys.get_state(Notifications)

  defp start(sender, recipients, body \\ "Secret plans") do
    {:ok, conversation} =
      Messaging.start_conversation(sender, %{
        "recipients" => recipients,
        "title" => "Hush",
        "body" => body
      })

    flush()
    conversation
  end

  defp reply(conversation, user, body) do
    {:ok, message} = Messaging.reply(conversation, user, %{body: body})
    flush()
    message
  end

  defp errors(sender, attrs) do
    {:error, changeset} = Messaging.start_conversation(sender, attrs)
    errors_on(changeset)
  end

  describe "starting a conversation" do
    test "makes the sender and recipients participants; recipients are notified and emailed",
         %{alice: alice, bob: bob, carol: carol} do
      conversation = start(alice, "@bob, carol")

      assert Enum.map(Messaging.participants(conversation), & &1.username) ==
               ~w(alice bob carol)

      assert [%{body: "Secret plans", user_id: alice_id}] = Messaging.messages(conversation)
      assert alice_id == alice.id

      assert Messaging.unread_conversation_count(alice) == 0
      assert Messaging.unread_conversation_count(bob) == 1

      assert [notification] = Notifications.notifications_for(bob)
      assert notification.kind == "message"
      assert notification.subject == ~s(@alice sent you a message: "Hush")
      assert notification.conversation_id == conversation.id
      assert notification.emailed_at
      assert [_] = Notifications.notifications_for(carol)
      assert Notifications.notifications_for(alice) == []

      assert_email_delivered_with(
        to: [nil: "bob@example.com"],
        subject: ~s(@alice sent you a message: "Hush" on Firefly)
      )
    end

    test "validates recipients, title and body", %{alice: alice} do
      assert %{recipients: ["no such user: @nobody"]} =
               errors(alice, %{"recipients" => "bob nobody", "title" => "t", "body" => "b"})

      assert %{recipients: ["add at least one other person"]} =
               errors(alice, %{"recipients" => "@alice", "title" => "t", "body" => "b"})

      assert %{
               recipients: ["can't be blank"],
               title: ["can't be blank"],
               body: ["can't be blank"]
             } =
               errors(alice, %{"recipients" => "", "title" => " ", "body" => ""})

      crowd = Enum.map_join(1..Messaging.max_participants(), " ", &user("crowd#{&1}").username)

      assert %{recipients: ["a conversation can have at most 20 people"]} =
               errors(alice, %{"recipients" => crowd, "title" => "t", "body" => "b"})
    end

    test "users who don't allow private messages can't be messaged, except by admins",
         %{alice: alice} do
      user("hermit", %{})
      |> Accounts.update_preferences(%{allow_private_messages: false})

      assert %{recipients: ["@hermit doesn't accept private messages"]} =
               errors(alice, %{"recipients" => "hermit", "title" => "t", "body" => "b"})

      {:ok, role} = Groups.create_role("admin")
      {:ok, _} = Groups.add_role(alice, role)
      assert start(alice, "hermit")
    end

    test "new-user limits apply to the message", %{bob: bob} do
      newbie = Firefly.Repo.update!(Ecto.Changeset.change(user("newbie"), trust_level: 0))
      links = "https://a.example https://b.example https://c.example"

      assert %{body: ["new users can include at most 2 links per post"]} =
               errors(newbie, %{"recipients" => bob.username, "title" => "t", "body" => links})
    end
  end

  test "posting checks: confirmation and the new-conversation rate limit", %{alice: alice} do
    {:ok, unconfirmed} =
      Accounts.register_user(%{username: "fresh", email: "f@example.com", password: "password1"})

    assert Posting.check(unconfirmed, :new_conversation) == {:error, :unconfirmed}

    config = Application.get_env(:firefly, RateLimit)

    Application.put_env(:firefly, RateLimit,
      # Day-long windows: Hammer windows are clock-aligned, so a minute one
      # could reset mid-test.
      limits: [post: {1_000, 86_400_000}, message: {1, 86_400_000}]
    )

    on_exit(fn -> Application.put_env(:firefly, RateLimit, config) end)

    assert Posting.check(alice, :new_conversation) == :ok
    assert Posting.check(alice, :new_conversation) == {:error, :rate_limited}
  end

  describe "replying" do
    test "notifies the other participants, emailing once until they read it",
         %{alice: alice, bob: bob} do
      conversation = start(alice, "bob")
      reply(conversation, bob, "Tell me more")

      assert [%{subject: ~s(@bob replied to "Hush"), emailed_at: %DateTime{}}] =
               Notifications.notifications_for(alice)

      reply(conversation, bob, "Hello?")
      assert [%{emailed_at: nil}, _] = Notifications.notifications_for(alice)
      assert Messaging.unread_conversation_count(alice) == 1

      :ok = Messaging.mark_read(conversation, alice)
      assert Messaging.unread_conversation_count(alice) == 0
      assert Notifications.unread_notification_count(alice) == 0

      reply(conversation, bob, "Again")
      assert [%{emailed_at: %DateTime{}} | _] = Notifications.notifications_for(alice)
    end

    test "respects the email preference and confirmation", %{alice: alice} do
      {:ok, quiet} = Accounts.update_preferences(user("quiet"), %{email_notifications: false})

      {:ok, unconfirmed} =
        Accounts.register_user(%{
          username: "unc",
          email: "unc@example.com",
          password: "password1"
        })

      start(alice, "quiet unc")

      assert [%{kind: "message", emailed_at: nil}] = Notifications.notifications_for(quiet)
      assert [%{kind: "message", emailed_at: nil}] = Notifications.notifications_for(unconfirmed)
      refute_email_delivered_with(to: [nil: "quiet@example.com"])
      refute_email_delivered_with(to: [nil: "unc@example.com"])
    end

    test "only participants can reply", %{alice: alice, carol: carol} do
      conversation = start(alice, "bob")
      assert Messaging.reply(conversation, carol, %{body: "Let me in"}) == {:error, :unauthorized}
    end

    test "message emails have no reply-by-email address", %{alice: alice} do
      start(alice, "bob")

      assert_delivered_email_matches(%{to: [nil: "bob@example.com"], headers: headers})
      refute Map.has_key?(headers, "reply-to")
    end
  end

  describe "participants" do
    test "the starter and admins in it can add people; others can't",
         %{alice: alice, bob: bob, carol: carol} do
      conversation = start(alice, "bob")

      assert Policy.authorize(:add_participants, alice, conversation) == :ok
      assert Policy.authorize(:add_participants, bob, conversation) == {:error, :unauthorized}
      assert Policy.authorize(:add_participants, carol, conversation) == {:error, :unauthorized}

      {:ok, role} = Groups.create_role("admin")
      {:ok, _} = Groups.add_role(bob, role)
      assert Policy.authorize(:add_participants, bob, conversation) == :ok

      admin = user("outsider")
      {:ok, _} = Groups.add_role(admin, role)
      assert Policy.authorize(:view_conversation, admin, conversation) == {:error, :unauthorized}
    end

    test "added people see the whole conversation and are notified", %{alice: alice, carol: carol} do
      conversation = start(alice, "bob")

      assert {:ok, [_carol]} = Messaging.add_participants(conversation, alice, "@carol")
      flush()

      assert Messaging.participant?(conversation, carol)
      assert [%{body: "Secret plans"}] = Messaging.messages(conversation)
      assert [%{subject: ~s(@alice added you to "Hush")}] = Notifications.notifications_for(carol)

      assert Messaging.add_participants(conversation, alice, "carol") ==
               {:error, "add at least one other person"}
    end

    test "leaving removes the conversation and its notifications, and sticks",
         %{alice: alice, bob: bob} do
      conversation = start(alice, "bob")
      :ok = Messaging.leave(conversation, bob)

      refute Messaging.participant?(conversation, bob)
      assert Notifications.notifications_for(bob) == []
      assert Messaging.inbox(bob, 1).entries == []
      assert Messaging.unread_conversation_count(bob) == 0

      reply(conversation, alice, "Still there?")
      assert Notifications.notifications_for(bob) == []

      assert Messaging.add_participants(conversation, alice, "bob") ==
               {:error, "@bob left this conversation"}

      flush()
      refute Messaging.participant?(conversation, bob)
      assert Notifications.notifications_for(bob) == []
    end

    test "adding people counts towards the message rate limit", %{alice: alice, carol: carol} do
      conversation = start(alice, "bob")
      config = Application.get_env(:firefly, RateLimit)
      on_exit(fn -> Application.put_env(:firefly, RateLimit, config) end)

      # Day-long window, so the test can't straddle a window boundary.
      Application.put_env(:firefly, RateLimit, limits: [message: {1, :timer.hours(24)}])
      {:ok, _} = Messaging.add_participants(conversation, alice, "carol")
      user("dave")

      assert Messaging.add_participants(conversation, alice, "dave") ==
               {:error, RateLimit.message()}

      assert Enum.map(Messaging.participants(conversation), & &1.username) ==
               ["alice", "bob", carol.username]
    end
  end

  test "notifications don't carry the message", %{alice: alice, bob: bob} do
    start(alice, "bob", "xylophone confidential")
    assert [%{body: body}] = Notifications.notifications_for(bob)
    refute body =~ "xylophone"
  end

  test "a deleted author's messages still show and notify", %{alice: alice, bob: bob} do
    conversation = start(alice, "bob")
    message = reply(conversation, bob, "Bye")
    # As Kaffy's user delete would, once nothing else references bob.
    Firefly.Repo.delete_all(
      Ecto.Query.where(Firefly.Notifications.Notification, user_id: ^bob.id)
    )

    {:ok, _} = Accounts.delete_user(bob)

    assert [_, %{user: nil}] = Messaging.messages(conversation)
    :ok = Notifications.message_created(message)
    flush()
    assert %{subject: ~s(Someone replied to "Hush")} = hd(Notifications.notifications_for(alice))
  end

  test "the inbox lists the user's conversations, most recent first, with unread counts",
       %{alice: alice, bob: bob} do
    older = start(alice, "bob")
    newer = start(alice, "carol")
    reply(older, bob, "Bump")

    assert [%{id: first, unread_count: 1}, %{id: second, unread_count: 0}] =
             Messaging.inbox(alice, 1).entries

    assert {first, second} == {older.id, newer.id}
    assert Messaging.inbox(user("dave"), 1).entries == []
  end

  test "messages stay out of everything public", %{alice: alice, bob: bob, carol: carol} do
    {:ok, category} = Discussion.create_category(%{title: "Public"})
    {:ok, thread} = Discussion.create_thread(category, carol, %{title: "Open", body: "Hello"})
    flush()

    start(alice, "bob", "xylophone confidential")

    assert Search.run(Search.parse("xylophone"), nil).entries == []
    assert Search.run(Search.parse("xylophone"), carol).entries == []
    assert Enum.map(Discussion.latest_threads(carol), & &1.id) == [thread.id]
    assert Discussion.user_posts(alice, nil, %{page: 1}).entries == []
    assert Notifications.notifications_for(carol) == []
    assert Discussion.participating_threads(bob) == []
  end
end
