defmodule FireflyImport.DiscourseTest do
  # The source database is shared by the module's tests.
  use Firefly.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias Firefly.{Import, Repo}
  alias Firefly.Accounts.{User, UserIdentity}
  alias Firefly.Chat
  alias Firefly.Discussion.{Category, Poll, Post, PostLike, Tag, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Import.Run
  alias Firefly.Messaging.{Conversation, Message}
  alias Firefly.Uploads.Upload
  alias FireflyImport.SourceDatabases
  alias FireflyImport.Sources.Discourse

  @fixtures Path.expand("../fixtures/discourse", __DIR__)

  setup_all do
    url =
      SourceDatabases.postgres("firefly_import_discourse", Path.join(@fixtures, "discourse.sql"))

    {:ok, url: url}
  end

  defp import!(url, opts \\ []) do
    FireflyImport.run(
      "discourse",
      [source_url: url, uploads_dir: Path.join(@fixtures, "uploads"), skip_after: true] ++ opts
    )
  end

  defp user(username), do: Repo.get_by!(User, username: username)
  defp thread(title), do: Repo.get_by!(Thread, title: title) |> Repo.preload([:tags, :posts])

  test "imports users, groups, categories, topics, posts and the rest", %{url: url} do
    assert {:ok, %Run{status: "finished"} = run} = import!(url)

    # Users: valid unique usernames, no password, emails, SSO and social logins.
    alice = user("alice_smith")
    assert alice.name == "Alice Smith"
    assert alice.email == "alice@example.com"
    assert alice.password_hash == nil
    assert alice.confirmed_at
    assert alice.trust_level == 3
    assert alice.bio == "I like **Elixir**."
    assert alice.website == "https://alice.example.com"
    assert alice.inserted_at == ~N[2020-01-02 10:00:00.000000]
    assert alice.avatar_upload_id
    bob = user("bob")
    assert bob.suspended_until
    refute user("carol").confirmed_at
    refute Repo.get_by(User, username: "system")

    assert Repo.get_by!(UserIdentity, provider: "discourse_connect", uid: "sso-alice").user_id ==
             alice.id

    assert Repo.get_by!(UserIdentity, provider: "github", uid: "4242").user_id == bob.id

    # Groups (not automatic ones) and members.
    team = Repo.get_by!(Role, name: "team")
    assert Import.mapped("discourse", "group", [10]) == %{}
    assert Repo.get_by!(RoleMembership, role_id: team.id, user_id: alice.id).owner

    # Categories: nested one level, colors, restricted, Q&A.
    general = Repo.get_by!(Category, title: "General")
    assert general.color == "#0088CC"
    assert general.description == "Talk about anything."
    help = Repo.get_by!(Category, title: "Help")
    assert help.parent_id == general.id
    assert help.allow_accepted_answers
    assert Repo.get_by!(Category, title: "Deep").parent_id == general.id

    assert Repo.preload(Repo.get_by!(Category, title: "Team"), :roles).roles |> Enum.map(& &1.id) ==
             [team.id]

    # Tags and tag groups.
    assert Repo.get_by!(Tag, name: "elixir")
           |> Repo.preload(:group)
           |> Map.get(:group)
           |> Map.get(:name) ==
             "Languages"

    # Topics and posts, with original timestamps and authors.
    welcome = thread("Welcome to the forum")
    assert welcome.category_id == general.id
    assert welcome.views == 42
    assert welcome.pinned_at
    assert welcome.inserted_at == ~N[2020-03-01 09:00:00.000000]
    assert Enum.map(welcome.tags, & &1.name) == ["elixir", "phoenix-framework"]
    [first, reply, from_deleted] = welcome.posts
    assert first.user_id == alice.id
    assert first.wiki
    assert first.edited_at == ~N[2020-03-01 10:00:00.000000]
    assert first.body =~ "Hello **everyone**!"
    refute first.body =~ "[poll"
    upload = Repo.get_by!(Upload, post_id: first.id)
    assert first.body =~ "![logo](/uploads/#{upload.token}/logo.png)"
    assert reply.user_id == bob.id
    assert reply.body =~ "@alice_smith said:"
    assert reply.body =~ "<strong>Alice</strong>"
    assert from_deleted.body == "From a **deleted** user, see [this](https://example.com)."
    assert Repo.get!(User, from_deleted.user_id).username == "imported-99"
    refute Repo.get_by(Thread, title: "Deleted topic")

    help_thread = thread("How do I deploy?")
    assert help_thread.closed_at
    [question, answer, spam] = help_thread.posts
    assert help_thread.accepted_post_id == answer.id
    assert spam.deleted_at
    assert question.user_id == bob.id

    # Likes (not withdrawn ones), bookmarks of posts, polls with votes.
    assert Repo.exists?(
             from(l in PostLike, where: l.post_id == ^first.id and l.user_id == ^bob.id)
           )

    assert Repo.exists?(
             from(l in PostLike, where: l.post_id == ^reply.id and l.user_id == ^alice.id)
           )

    refute Repo.exists?(from(l in PostLike, where: l.post_id == ^question.id))
    answer_id = answer.id
    assert [{^answer_id, "the answer"}] = bookmarks(bob)

    poll = Repo.get_by!(Poll, post_id: first.id) |> Repo.preload([:options, :votes])
    assert Enum.map(poll.options, & &1.text) == ["Yes", "No"]
    assert poll.public
    assert poll.closed_at
    assert length(poll.votes) == 2

    # Private messages.
    conversation =
      Repo.get_by!(Conversation, title: "Hi Bob") |> Repo.preload([:participants, :messages])

    assert conversation.user_id == alice.id

    assert conversation.participants |> Enum.map(& &1.user_id) |> Enum.sort() ==
             Enum.sort([alice.id, bob.id])

    assert Enum.map(conversation.messages, & &1.body) == ["Hi Bob, how are you?", "Fine, thanks!"]
    assert conversation.last_message_at == ~N[2020-05-01 09:00:00.000000]
    refute Repo.exists?(from(t in Thread, where: t.title == "Hi Bob"))

    # Permalinks to topics, categories, users, tags and Discourse's own.
    assert Import.find_permalink("/t/welcome-to-the-forum/100").thread_id == welcome.id
    assert Import.find_permalink("/t/welcome-to-the-forum/100/2").thread_id == welcome.id
    assert Import.find_permalink("/t/100").thread_id == welcome.id
    assert Import.find_permalink("/c/general/help").category_id == help.id
    assert Import.find_permalink("/u/alice.smith").user_id == alice.id
    assert Import.find_permalink("/tag/elixir").tag_id
    assert Import.find_permalink("/old/welcome.html").thread_id == welcome.id
    assert Import.find_permalink("/old/answer").post_id == answer.id
    assert Import.find_permalink("/old/elsewhere").external_url == "https://example.org/"

    # The run's counts and log.
    assert run.counts["posts"] == %{"imported" => 7}
    assert run.counts["users"] == %{"imported" => 3}
    assert Enum.any?(run.log, &(&1 =~ "posts: done"))
    refute Chat.Channel |> Repo.exists?()
    assert Repo.aggregate(Message, :count) == 2
  end

  defp bookmarks(user) do
    Repo.all(
      from(b in "forums_bookmarks", where: b.user_id == ^user.id, select: {b.post_id, b.note})
    )
  end

  test "a second run imports nothing twice", %{url: url} do
    assert {:ok, _run} = import!(url)

    counts =
      for schema <- [User, Thread, Post, PostLike, Category, Upload],
          into: %{},
          do: {schema, Repo.aggregate(schema, :count)}

    assert {:ok, run} = import!(url)
    assert run.counts["posts"] == %{"skipped" => 7}
    assert run.counts["users"] == %{"skipped" => 3}

    for {schema, count} <- counts, do: assert(Repo.aggregate(schema, :count) == count)
  end

  test "a user with the same email is the existing account", %{url: url} do
    existing = Firefly.Fixtures.user_fixture(%{username: "alice", email: "ALICE@example.com"})
    assert {:ok, _run} = import!(url)
    refute Repo.get_by(User, username: "alice_smith")
    assert Repo.get_by!(UserIdentity, provider: "discourse_connect").user_id == existing.id
    assert thread("Welcome to the forum").posts |> hd() |> Map.get(:user_id) == existing.id
  end

  test "a dry run writes nothing but its run", %{url: url} do
    users = Repo.aggregate(User, :count)
    assert {:ok, run} = import!(url, dry_run: true)
    assert run.dry_run
    assert run.counts["posts"] == %{"imported" => 7}
    assert Repo.aggregate(User, :count) == users
    refute Repo.exists?(Thread)
    assert Import.mapped("discourse", "user", ["1"]) == %{}
  end

  test "runs from the command line, in small batches", %{url: url} do
    args = ["discourse", "--source-url", url, "--skip-after", "--batch-size", "2"]
    output = capture_io(fn -> assert FireflyImport.CLI.main(args) == 0 end)
    assert output =~ "posts: 2 imported, 0 skipped, 0 failed"
    assert output =~ "posts: done"
    assert Repo.get_by(Thread, title: "How do I deploy?")

    assert capture_io(:stderr, fn -> assert FireflyImport.CLI.main(["nope"]) == 2 end) =~
             "Unknown source"

    assert capture_io(:stderr, fn ->
             assert FireflyImport.CLI.main(["discourse", "--bogus"]) == 2
           end) =~
             "--source-url"
  end

  @tag :capture_log
  test "a source that can't be opened fails the run" do
    assert {:error, %Run{status: "failed", error: error}} =
             FireflyImport.run("discourse",
               source_url: "postgres://nobody:wrong@localhost:1/none"
             )

    assert error
  end

  test "converts Discourse's raw Markdown" do
    assert Discourse.convert_raw(~s{[quote="jane.doe, post:2, topic:9, full:true"]\nHi\n[/quote]}) ==
             "[quote=jane_doe]\nHi\n[/quote]"

    assert Discourse.convert_raw("Ask @jane.doe, not bob@example.com") ==
             "Ask @jane_doe, not bob@example.com"

    assert Discourse.convert_raw("![a cat|690x388, 50%](upload://abc.png)") ==
             "![a cat](upload://abc.png)"
  end
end
