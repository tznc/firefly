defmodule Firefly.AkismetTest do
  # Akismet's base URL is global.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Accounts, Chat, Discussion, FakeAkismet, Messaging, Reports, SiteSettings}
  alias Firefly.Discussion.Post
  alias Firefly.Messaging.Message
  alias Firefly.Moderation.{Akismet, AkismetCheck, Flag, Flags, Review, StaffAction}

  setup do
    admin = admin_fixture(%{username: "boss"})
    FakeAkismet.setup()
    Akismet.put_client(%{ip: "203.0.113.9", user_agent: "Spambot/1.0", referrer: "https://ref"})
    %{admin: admin, alice: member("alice"), category: category_fixture()}
  end

  defp member(username, trust_level \\ 1) do
    {:ok, user} = Accounts.confirm_user(user_fixture(%{username: username}))
    Repo.update!(Ecto.Changeset.change(user, trust_level: trust_level))
  end

  defp reply(ctx, body) do
    thread = thread_fixture(ctx.category, ctx.admin)
    {:ok, post} = Discussion.create_post(thread, ctx.alice, %{body: body})
    Repo.get!(Post, post.id)
  end

  defp check(kind, id), do: Repo.get_by!(AkismetCheck, kind: kind, subject_id: id)

  describe "posts" do
    test "spam is hidden and flagged for review, with what Akismet needs", ctx do
      post = reply(ctx, "Cheap viagra here")

      assert_received {:akismet, "comment-check", params}
      assert params["api_key"] == "good-key"
      assert params["comment_content"] == "Cheap viagra here"
      assert params["comment_type"] == "reply"
      assert params["comment_author"] == "alice"
      assert params["user_ip"] == "203.0.113.9"
      assert params["user_agent"] == "Spambot/1.0"
      assert params["blog"] =~ "http"
      assert params["permalink"] =~ "#post-#{post.id}"

      assert Post.hidden?(post)
      assert [%Flag{reason: "spam", note: "Akismet: spam", user_id: nil}] = Repo.all(Flag)

      assert %AkismetCheck{spam: true, status: "pending", user_id: user_id} =
               check("post", post.id)

      assert user_id == ctx.alice.id
      assert Repo.get_by(StaffAction, action: "akismet.spam")
    end

    test "ham stands, and is recorded", ctx do
      post = reply(ctx, "A thoughtful reply")
      refute Post.hidden?(post)
      assert Repo.all(Flag) == []
      assert %AkismetCheck{spam: false, status: "clean"} = check("post", post.id)
    end

    test "trusted members, admins and switched-off kinds aren't checked", ctx do
      trusted = member("tess", 2)
      thread = thread_fixture(ctx.category, ctx.admin)
      {:ok, _} = Discussion.create_post(thread, trusted, %{body: "viagra"})
      {:ok, _} = Discussion.create_post(thread, ctx.admin, %{body: "viagra"})
      refute_received {:akismet, _, _}

      {:ok, _} = SiteSettings.update(%{"akismet_check_posts" => "false"}, ctx.admin)
      {:ok, _} = Discussion.create_post(thread, ctx.alice, %{body: "viagra"})
      refute_received {:akismet, _, _}

      {:ok, _} =
        SiteSettings.update(
          %{"akismet_check_posts" => "true", "akismet_enabled" => "false"},
          ctx.admin
        )

      {:ok, _} = Discussion.create_post(thread, ctx.alice, %{body: "viagra"})
      refute_received {:akismet, _, _}
    end

    @tag :capture_log
    test "Akismet failing never stops posting", ctx do
      FakeAkismet.setup(%{}, fn _call, _params -> "oops" end)
      post = reply(ctx, "viagra")
      refute Post.hidden?(post)
      assert Repo.all(AkismetCheck) == []
    end

    test "staff confirming spam or finding it isn't is reported back once", ctx do
      post = reply(ctx, "viagra")
      assert {:ok, _} = Review.agree(post, ctx.admin, :delete)
      assert_received {:akismet, "submit-spam", %{"comment_content" => "viagra"}}
      assert %AkismetCheck{status: "confirmed", feedback: "spam"} = check("post", post.id)

      other = reply(ctx, "more viagra")
      assert {:ok, _} = Review.disagree(other, ctx.admin)
      assert_received {:akismet, "submit-ham", %{"comment_content" => "more viagra"}}
      assert %AkismetCheck{status: "not_spam", feedback: "ham"} = check("post", other.id)
      refute Post.hidden?(Repo.get!(Post, other.id))
    end

    test "spam Akismet missed, flagged by members, is reported as spam", ctx do
      post = reply(ctx, "Sneaky spam")
      {:ok, _} = Flags.flag_post(post, member("flagger", 2), %{reason: "spam"})
      assert {:ok, _} = Review.agree(post, ctx.admin, :hide)
      assert_received {:akismet, "submit-spam", _}
      assert %AkismetCheck{status: "clean", feedback: "spam"} = check("post", post.id)
    end

    test "a post AI triage flagged too is queued once", ctx do
      post = reply(ctx, "A thoughtful reply")
      {:ok, _} = Flags.flag_by_system(post, "AI triage: spammy (toxicity 0, spam 90)")
      {:ok, _} = Flags.hide_by_system(post, Akismet.flag_note(), "spam")

      assert [flag] = Repo.all(Flag)
      assert flag.note == "AI triage: spammy (toxicity 0, spam 90); Akismet: spam"
      assert Akismet.flag?(flag)
      assert Review.pending_count() == 1
    end
  end

  test "chat spam is flagged; deciding it is reported back", ctx do
    {:ok, general} = Chat.create_channel(%{"name" => "General"}, ctx.admin)
    {:ok, message} = Chat.send_message(general, ctx.alice, %{"body" => "viagra deals"})

    assert [%{id: id, flags: [flag]}] = Chat.flagged_messages()
    assert id == message.id
    assert Akismet.flag?(flag)

    {:ok, _} = Chat.review_flags(message, ctx.admin, :agree)
    assert_received {:akismet, "submit-spam", _}
  end

  describe "private messages and profiles" do
    test "spam waits in the queue; confirming deletes the message", ctx do
      {:ok, conversation} =
        Messaging.start_conversation(ctx.alice, %{
          "recipients" => "boss",
          "title" => "Hi",
          "body" => "viagra for you"
        })

      assert [pending] = Akismet.pending()
      assert pending.kind == "message"
      assert Review.pending_count() == 1

      assert {:ok, _} = Akismet.review(pending.id, ctx.admin, :spam)
      assert_received {:akismet, "submit-spam", _}
      assert Messaging.messages(conversation) == []
      assert Repo.get_by(StaffAction, action: "akismet.confirm")
      assert {:error, :not_pending} = Akismet.review(pending.id, ctx.admin, :ham)
      assert Akismet.pending() == []
    end

    test "not spam leaves the message", ctx do
      {:ok, _} =
        Messaging.start_conversation(ctx.alice, %{
          "recipients" => "boss",
          "title" => "Hi",
          "body" => "viagra, the word"
        })

      [pending] = Akismet.pending()
      assert {:ok, _} = Akismet.review(pending.id, ctx.admin, :ham)
      assert_received {:akismet, "submit-ham", _}
      assert Repo.aggregate(Message, :count) == 1
    end

    test "a spammy profile is queued; confirming clears it", ctx do
      {:ok, _} =
        Accounts.update_user(ctx.alice, %{bio: "Buy viagra", website: "https://pills.example"})

      assert_received {:akismet, "comment-check", %{"comment_type" => "signup"}}

      [pending] = Akismet.pending()
      assert pending.kind == "profile"
      assert {:ok, _} = Akismet.review(pending.id, ctx.admin, :spam)

      user = Accounts.get_user!(ctx.alice.id)
      assert {user.bio, user.website} == {nil, nil}

      # Other profile changes aren't checked.
      {:ok, _} = Accounts.update_user(user, %{name: "Alice"})
      refute_received {:akismet, "comment-check", _}
    end
  end

  test "the API key is checked, and never written to the staff log", ctx do
    assert :ok = Akismet.verify_key()
    {:ok, _} = SiteSettings.update(%{"akismet_api_key" => "bad-key"}, ctx.admin)
    assert {:error, :invalid_key} = Akismet.verify_key()

    log = Repo.get_by!(StaffAction, action: "setting.update")
    refute inspect(log.details) =~ "bad-key"
  end

  test "the report counts checks, spam and decisions", ctx do
    post = reply(ctx, "viagra")
    reply(ctx, "Fine")
    {:ok, _} = Review.agree(post, ctx.admin, :hide)

    {:series, series} = Reports.get("akismet").run(Reports.last(1))
    totals = Map.new(series, &{&1.key, &1.points |> Enum.map(fn {_d, n} -> n end) |> Enum.sum()})
    assert totals == %{"checked" => 2, "spam" => 1, "confirmed" => 1, "not_spam" => 0}
  end
end
