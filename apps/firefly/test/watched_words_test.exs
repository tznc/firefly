defmodule Firefly.WatchedWordsTest do
  use Firefly.DataCase
  # A silenced author is emailed.
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  alias Firefly.{Accounts, Discussion, Messaging}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Moderation.{Review, StaffAction, WatchedWord, WatchedWords}
  alias Firefly.Rendering.Markdown

  import Firefly.Fixtures

  setup do
    # The cache is global; each test's words are rolled back with it.
    on_exit(fn -> WatchedWords.put_cache(%{}) end)
    %{admin: admin_fixture(), author: user_fixture(), category: category_fixture()}
  end

  defp watch(admin, action, word, attrs \\ %{}) do
    {:ok, word} =
      WatchedWords.create(admin, Map.merge(%{"word" => word, "action" => action}, attrs))

    word
  end

  describe "matching" do
    test "is case-insensitive, whole-word, with * wildcards", %{admin: admin} do
      watch(admin, "flag", "spam*")
      watch(admin, "flag", "ass")

      assert WatchedWords.match("SPAMMER and Spam here", "flag") == ["spammer", "spam"]
      assert WatchedWords.match("a class of its own", "flag") == []
      assert WatchedWords.match("you ass.", "flag") == ["ass"]
      assert WatchedWords.match("nothing", "block") == []
      assert WatchedWords.match(nil, "flag") == []
    end

    # Found by Firefly.ModerationPropertyTest: a regex that backtracks
    # catastrophically reached PCRE's match limit after a fifth of a second,
    # and Regex raised, failing the post and every page showing it.
    test "a regex that backtracks too much gives up fast and matches nothing", %{
      admin: admin,
      author: author,
      category: category
    } do
      for action <- ~w(block censor link) do
        attrs = %{"regex" => "true", "replacement" => "https://example.com/rules"}
        watch(admin, action, "(a+)+$", attrs)
      end

      text = String.duplicate("a", 30) <> "!"
      {microseconds, matches} = :timer.tc(fn -> WatchedWords.match(text, "block") end)
      assert matches == []
      assert microseconds < 100_000
      assert WatchedWords.censor(text) == text
      assert Markdown.render(text) == "<p>#{text}</p>"

      assert {:ok, _thread} =
               Discussion.create_thread(category, author, %{title: "Hello there", body: text})
    end

    test "regex mode uses the expression as it is", %{admin: admin} do
      watch(admin, "block", "c[a@]sino\\d*", %{"regex" => "true"})
      assert WatchedWords.match("cheap c@sino99 deals", "block") == ["c@sino99"]
    end

    test "compile/1 is pure", %{admin: _admin} do
      matchers =
        WatchedWords.compile([%WatchedWord{word: "foo", action: "censor", regex: false}])

      assert [{%WatchedWord{word: "foo"}, regex}] = matchers["censor"]
      assert Regex.match?(regex, "a FOO b")
    end

    test "words are validated", %{admin: admin} do
      assert {:error, changeset} =
               WatchedWords.create(admin, %{"word" => "(", "action" => "block", "regex" => "true"})

      assert errors_on(changeset).word == ["is not a valid regular expression"]

      assert {:error, changeset} =
               WatchedWords.create(admin, %{"word" => "**", "action" => "block"})

      assert errors_on(changeset).word == ["needs more than wildcards"]

      assert {:error, changeset} =
               WatchedWords.create(admin, %{
                 "word" => "x",
                 "action" => "link",
                 "replacement" => "javascript:alert(1)"
               })

      assert errors_on(changeset).replacement == ["must be an http(s) URL or a path on this site"]

      watch(admin, "block", "dup")

      assert {:error, changeset} =
               WatchedWords.create(admin, %{"word" => "DUP", "action" => "block"})

      assert errors_on(changeset).word == ["is already watched for this action"]
    end

    test "adding and removing are logged", %{admin: admin} do
      word = watch(admin, "censor", "darn")
      assert :ok = WatchedWords.delete(word, admin)

      assert ["watched_word.create", "watched_word.delete"] =
               StaffAction |> order_by(:id) |> select([a], a.action) |> Repo.all()

      assert WatchedWords.list("censor") == []
    end
  end

  describe "posting" do
    test "a blocked word refuses titles, posts and messages", ctx do
      watch(ctx.admin, "block", "casino")

      assert {:error, changeset} =
               Discussion.create_thread(ctx.category, ctx.author, %{title: "Casino", body: "Hi"})

      assert errors_on(changeset).title == ["contains a word that's not allowed: casino"]

      thread = thread_fixture(ctx.category, ctx.author)

      assert {:error, changeset} =
               Discussion.create_post(thread, ctx.author, %{body: "visit my casino"})

      assert errors_on(changeset).body == ["contains a word that's not allowed: casino"]

      post = hd(Repo.preload(thread, :posts).posts)
      assert {:error, changeset} = Discussion.update_post(post, ctx.author, %{body: "casino!"})
      assert errors_on(changeset).body != []

      assert {:error, changeset} =
               Messaging.start_conversation(ctx.author, %{
                 "recipients" => ctx.admin.username,
                 "title" => "Hi",
                 "body" => "casino"
               })

      assert errors_on(changeset).body != []
    end

    test "a word needing approval queues the post, except for admins", ctx do
      watch(ctx.admin, "require_approval", "crypto")
      thread = thread_fixture(ctx.category, ctx.author)

      {:ok, post} = Discussion.create_post(thread, ctx.author, %{body: "Buy crypto"})
      assert Post.queued?(post)
      assert post.queued_reason == "Watched words: crypto"
      assert [%{id: id}] = Review.queued_posts()
      assert id == post.id

      {:ok, post} = Discussion.create_post(thread, ctx.admin, %{body: "About crypto"})
      refute Post.queued?(post)
    end

    test "a word in a new thread's title queues its first post", ctx do
      watch(ctx.admin, "require_approval", "crypto")
      thread = thread_fixture(ctx.category, ctx.author, %{title: "Crypto news"})
      assert Discussion.queued_thread_author_id(thread) == ctx.author.id
    end

    test "a flagged word publishes the post and flags it as the system", ctx do
      watch(ctx.admin, "flag", "idiot")
      thread = thread_fixture(ctx.category, ctx.author)

      {:ok, post} = Discussion.create_post(thread, ctx.author, %{body: "you idiot"})
      refute Post.queued?(post)

      assert [%{id: id, flags: [flag]}] = Review.flagged_posts()
      assert id == post.id
      assert flag.user_id == nil
      assert flag.note == "Watched words: idiot"
    end

    test "a silencing word silences the author and queues the post", ctx do
      watch(ctx.admin, "silence", "viagra")
      thread = thread_fixture(ctx.category, ctx.author)

      {:ok, post} = Discussion.create_post(thread, ctx.author, %{body: "cheap viagra"})
      assert Post.queued?(post)
      assert User.silenced?(Accounts.get_user!(ctx.author.id))

      assert %StaffAction{actor_id: nil, action: "user.silence"} =
               Repo.get_by(StaffAction, action: "user.silence")
    end

    test "a tag word tags new threads", ctx do
      watch(ctx.admin, "tag", "phoenix", %{"replacement" => "web, elixir"})

      thread = thread_fixture(ctx.category, ctx.author, %{title: "Phoenix question", body: "Hi"})

      assert thread.id
             |> then(&Repo.get!(Thread, &1))
             |> Repo.preload(:tags)
             |> Map.get(:tags)
             |> Enum.map(& &1.name) == ["elixir", "web"]
    end
  end

  describe "rendering" do
    test "censors, replaces and links words in text, not code", ctx do
      watch(ctx.admin, "censor", "darn")
      watch(ctx.admin, "replace", "teh", %{"replacement" => "the"})
      watch(ctx.admin, "link", "elixir", %{"replacement" => "https://elixir-lang.org"})

      html = Markdown.render("Darn, teh Elixir docs. `darn`")

      assert html =~ "■■■■, the"
      assert html =~ ~s{<a href="https://elixir-lang.org" rel="noopener noreferrer">Elixir</a>}
      assert html =~ "<code>darn</code>"
      assert WatchedWords.censor("Darn title") == "■■■■ title"
    end

    test "doesn't link inside links", ctx do
      watch(ctx.admin, "link", "elixir", %{"replacement" => "https://elixir-lang.org"})
      html = Markdown.render("[about elixir](https://example.com)")
      refute html =~ "elixir-lang.org"
    end
  end
end
