defmodule Firefly.AIFeaturesTest do
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Accounts, AI, Chat, Discussion, Groups, Reports, SiteSettings}
  alias Firefly.AI.{Classification, Composer, FakeProvider, Summaries, Translations, Triage}
  alias Firefly.Discussion.Post
  alias Firefly.Moderation.{Flag, Flags, StaffAction}

  setup do
    admin = admin_fixture(%{username: "boss"})
    %{admin: admin, alice: member("alice"), bob: member("bob"), category: category_fixture()}
  end

  defp member(username) do
    {:ok, user} = Accounts.confirm_user(user_fixture(%{username: username}))
    Repo.update!(Ecto.Changeset.change(user, trust_level: 1))
  end

  defp settings(admin, params), do: {:ok, _} = SiteSettings.update(params, admin)

  # A provider answering every request with `answer` (a function of the
  # request body, or text), switched on for `features`.
  defp provider(admin, features, answer) do
    url =
      FakeProvider.start(fn conn ->
        text = if is_function(answer, 1), do: answer.(conn.assigns.body), else: answer
        FakeProvider.openai_reply(conn, text)
      end)

    provider = FakeProvider.provider_fixture(url)
    :ok = FakeProvider.enable(provider, features, admin)
    provider
  end

  defp user_content(%{"messages" => messages}),
    do: Enum.find_value(messages, &(&1["role"] == "user" && &1["content"]))

  defp reply(thread, user, body) do
    {:ok, post} = Discussion.create_post(thread, user, %{body: body})
    post
  end

  describe "topic summaries" do
    test "summarize the published posts once, until enough new ones", ctx do
      provider(ctx.admin, "summarize", "The gist")
      settings(ctx.admin, %{"ai_summary_min_posts" => "3", "ai_summary_stale_posts" => "2"})

      thread =
        thread_fixture(ctx.category, ctx.alice, %{title: "Big question", body: "What now?"})

      reply(thread, ctx.bob, "Try this")
      hidden = reply(thread, ctx.bob, "Hidden words")
      Repo.update!(Ecto.Changeset.change(hidden, hidden_at: DateTime.utc_now(:second)))

      refute Summaries.summarizable?(2)
      assert Summaries.summarizable?(3)

      test = self()
      stream = &send(test, {:delta, &1})

      assert {:ok, %{text: "The gist", cached: false}} =
               Summaries.topic(thread, ctx.bob, stream: stream)

      assert_received {:delta, "The "}

      assert_received {:ai_request, %{body: body}}
      content = user_content(body)
      assert content =~ "Topic: Big question"
      assert content =~ "@alice:\nWhat now?"
      assert content =~ "Try this"
      refute content =~ "Hidden words"

      # Cached for everyone, not counted.
      assert {:ok, %{text: "The gist", cached: true}} = Summaries.topic(thread, ctx.alice)
      refute_received {:ai_request, _}
      assert AI.used_today(ctx.alice) == 0

      reply(thread, ctx.alice, "One more")
      assert {:ok, %{cached: true}} = Summaries.topic(thread, ctx.alice)
      reply(thread, ctx.alice, "And another")
      assert {:ok, %{cached: false}} = Summaries.topic(thread, ctx.alice)
    end

    test "only for readers of the topic, while the feature is on", ctx do
      {:ok, team} = Groups.create_role("team")
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      thread = thread_fixture(secret, ctx.admin)

      assert {:error, :disabled} = Summaries.topic(thread, ctx.alice)
      provider(ctx.admin, "summarize", "Leak")
      assert {:error, :unauthorized} = Summaries.topic(thread, ctx.alice)
      refute_received {:ai_request, _}
    end
  end

  describe "chat summaries" do
    setup ctx do
      {:ok, general} = Chat.create_channel(%{"name" => "General"}, ctx.admin)
      %{general: general}
    end

    test "cover what the member hasn't read", ctx do
      provider(ctx.admin, "summarize", "You missed a lunch plan")
      :ok = Chat.follow(ctx.general, ctx.alice)
      {:ok, old} = Chat.send_message(ctx.general, ctx.bob, %{"body" => "Old news"})
      :ok = Chat.mark_read(ctx.general, ctx.alice, old.id)
      {:ok, _} = Chat.send_message(ctx.general, ctx.bob, %{"body" => "Lunch at noon?"})

      assert {:ok, %{text: "You missed a lunch plan", count: 1}} =
               Summaries.channel(ctx.general, ctx.alice)

      assert_received {:ai_request, %{body: body}}
      assert user_content(body) =~ "@bob: Lunch at noon?"
      refute user_content(body) =~ "Old news"
    end

    test "direct messages only for their members", ctx do
      provider(ctx.admin, "summarize", "Private")
      {:ok, dm} = Chat.direct_channel(ctx.alice, ["bob"])
      {:ok, _} = Chat.send_message(dm, ctx.alice, %{"body" => "Just us"})

      assert {:error, :unauthorized} = Summaries.channel(dm, member("carol"))
      assert {:ok, %{text: "Private"}} = Summaries.channel(dm, ctx.bob)
    end
  end

  describe "translations" do
    test "are cached per post and language, until the post is edited", ctx do
      provider(ctx.admin, "translate", &("FR: " <> user_content(&1)))
      thread = thread_fixture(ctx.category, ctx.alice, %{body: "Hello"})
      post = hd(Repo.preload(thread, :posts).posts)

      assert {:ok, %{text: "FR: Hello", cached: false}} =
               Translations.post(post, ctx.bob, "fr-FR")

      assert_received {:ai_request, %{body: body}}
      assert hd(body["messages"])["content"] =~ "into French"

      assert {:ok, %{cached: true}} = Translations.post(post, ctx.bob, "fr-fr")
      assert {:ok, %{cached: false}} = Translations.post(post, ctx.bob, "de")

      {:ok, post} = Discussion.update_post(post, ctx.alice, %{body: "Hello again"})
      assert {:ok, %{text: "FR: Hello again"}} = Translations.post(post, ctx.bob, "fr-FR")
    end

    test "only of what the member may read", ctx do
      provider(ctx.admin, "translate", "x")
      {:ok, team} = Groups.create_role("team")
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      post = hd(Repo.preload(thread_fixture(secret, ctx.admin), :posts).posts)
      assert {:error, :unauthorized} = Translations.post(post, ctx.alice, "fr")

      {:ok, dm} = Chat.direct_channel(ctx.admin, ["bob"])
      {:ok, message} = Chat.send_message(dm, ctx.admin, %{"body" => "Psst"})
      assert {:error, :unauthorized} = Translations.message(message, ctx.alice, "fr")
      assert {:ok, %{text: "x"}} = Translations.message(message, ctx.bob, "fr")
    end

    test "language tags" do
      assert Translations.language("pt-BR") == "pt-br"
      assert Translations.language("<script>") == "en"
      assert Translations.language_name("pt-br") == "Brazilian Portuguese"
      assert Translations.language_name("fr-ca") == "French"
      assert Translations.language_name("tlh") =~ "tlh"
    end
  end

  describe "triage" do
    defp rating(toxicity, spam, sentiment \\ "negative"),
      do:
        Jason.encode!(%{
          toxicity: toxicity,
          spam: spam,
          sentiment: sentiment,
          reason: "Looks like an ad"
        })

    test "rates new posts and flags those over the threshold, as the system", ctx do
      provider(ctx.admin, "triage", "Sure! " <> rating(10, 85))
      settings(ctx.admin, %{"ai_triage_tag" => "Needs Review"})
      thread = thread_fixture(ctx.category, ctx.alice, %{body: "Buy cheap watches"})
      post = hd(Repo.preload(thread, :posts).posts)

      assert %Classification{toxicity: 10, spam: 85, sentiment: "negative"} =
               Repo.get_by(Classification, post_id: post.id)

      assert [%Flag{user_id: nil, note: note}] = Repo.all(where(Flag, post_id: ^post.id))
      assert note =~ "AI triage: Looks like an ad" and note =~ "spam 85"
      refute Repo.get!(Post, post.id).hidden_at

      assert [%StaffAction{actor_id: nil, details: %{"spam" => 85}}] =
               Repo.all(where(StaffAction, action: "ai.flag"))

      assert ["needs-review"] =
               Enum.map(Repo.preload(Discussion.get_thread!(thread.id), :tags).tags, & &1.name)

      assert [%{feature: "triage", user_id: nil}] = Repo.all(AI.Usage)
    end

    test "hides posts over the hide threshold; leaves calm ones alone", ctx do
      provider(ctx.admin, "triage", fn body ->
        if user_content(body) =~ "idiot", do: rating(95, 0), else: rating(0, 0, "positive")
      end)

      settings(ctx.admin, %{"ai_triage_hide_threshold" => "90"})
      thread = thread_fixture(ctx.category, ctx.alice, %{body: "Nice day"})
      rude = reply(thread, ctx.bob, "You idiot")

      assert Repo.get!(Post, rude.id).hidden_at
      assert [_] = Repo.all(where(StaffAction, action: "ai.hide"))
      assert Repo.aggregate(Flag, :count) == 1

      {:series, series} = Reports.get("sentiment").run(Reports.last(1))

      assert Map.new(series, &{&1.key, &1.points |> hd() |> elem(1)}) ==
               %{"positive" => 1, "neutral" => 0, "negative" => 1}
    end

    test "rates a flagged post it hadn't, and ignores answers that aren't ratings", ctx do
      thread = thread_fixture(ctx.category, ctx.alice, %{body: "Before triage"})
      post = hd(Repo.preload(thread, :posts).posts)
      provider(ctx.admin, "triage", rating(5, 5, "neutral"))

      {:ok, _} = Flags.flag_post(post, ctx.bob, %{reason: "off_topic"})
      assert %Classification{sentiment: "neutral"} = Repo.get_by(Classification, post_id: post.id)
      assert Triage.classify(post) == :ok

      provider(ctx.admin, "triage", "I can't rate that")
      other = reply(thread, ctx.bob, "Hmm")
      refute Repo.get_by(Classification, post_id: other.id)
      assert {:error, :invalid_answer} = Triage.classify(other)
    end

    test "does nothing while off", ctx do
      thread = thread_fixture(ctx.category, ctx.alice)
      assert {:error, :disabled} = Triage.classify(hd(Repo.preload(thread, :posts).posts))
      assert Repo.all(Classification) == []
    end
  end

  describe "composer helpers" do
    test "proofread, suggest a title and tags, as staff allow", ctx do
      provider(ctx.admin, "composer", fn body ->
        case hd(body["messages"])["content"] do
          "Proofread" <> _ -> "Fixed text"
          "Suggest" <> _ -> "\"A title\""
          "Pick" <> _ -> ~s({"tags": ["Elixir", "OTP stuff", "elixir"]})
        end
      end)

      assert Composer.helpers(ctx.alice) == [:proofread, :title, :tags]
      assert {:ok, "Fixed text"} = Composer.proofread(ctx.alice, "teh text")
      assert {:ok, "A title"} = Composer.suggest_title(ctx.alice, "Some post")
      assert {:ok, ["elixir", "otp-stuff"]} = Composer.suggest_tags(ctx.alice, "Some post")
      assert {:error, :empty} = Composer.proofread(ctx.alice, "  ")

      settings(ctx.admin, %{"ai_composer_tags" => "false"})
      assert Composer.helpers(ctx.alice) == [:proofread, :title]
      assert {:error, :disabled} = Composer.suggest_tags(ctx.alice, "Some post")
    end
  end
end
