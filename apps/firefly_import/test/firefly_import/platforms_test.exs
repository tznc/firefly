defmodule FireflyImport.PlatformsTest do
  use Firefly.DataCase, async: false

  import Ecto.Query

  alias Firefly.AI.FakeProvider
  alias Firefly.Repo
  alias Firefly.Accounts.{User, UserIdentity}
  alias Firefly.Chat
  alias Firefly.Discussion.{Category, Post, PostLike, Thread}
  alias Firefly.Messaging.Conversation
  alias Firefly.Uploads.Upload
  alias FireflyImport.Sources.Slack

  @fixtures Path.expand("../fixtures", __DIR__)
  @logo Path.expand("../fixtures/discord/media/logo.png", __DIR__)

  describe "Slack" do
    # The export, zipped, with its file served (to the token) by a local server.
    setup do
      url =
        FakeProvider.start(fn conn ->
          if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-test"],
            do: Plug.Conn.send_resp(conn, 200, File.read!(@logo)),
            else: Plug.Conn.send_resp(conn, 403, "")
        end)

      dir = Path.join(System.tmp_dir!(), "slack-export-#{System.unique_integer([:positive])}")
      File.cp_r!(Path.join(@fixtures, "slack"), dir)
      general = Path.join(dir, "general/2020-01-01.json")

      File.write!(
        general,
        String.replace(File.read!(general), "FILE_URL", url <> "/files/logo.png")
      )

      zip = dir <> ".zip"

      files =
        dir
        |> Path.join("**/*.json")
        |> Path.wildcard()
        |> Enum.map(&String.to_charlist(Path.relative_to(&1, dir)))

      {:ok, _} = :zip.create(String.to_charlist(zip), files, cwd: String.to_charlist(dir))

      on_exit(fn ->
        File.rm_rf!(dir)
        File.rm(zip)
      end)

      {:ok, zip: zip}
    end

    test "imports channels as chat, with threads, files, reactions and direct messages", %{
      zip: zip
    } do
      ann = Firefly.Fixtures.user_fixture(%{username: "annie", email: "ANN@example.com"})

      assert {:ok, run} =
               FireflyImport.run("slack", path: zip, token: "xoxb-test", skip_after: true)

      assert run.counts["users"] == %{"imported" => 2}

      # Matched by email; the rest created with their Slack login.
      refute Repo.get_by(User, username: "ann")
      ben = Repo.get_by!(User, username: "ben_k")
      assert ben.name == "Ben K"
      assert Repo.get_by!(UserIdentity, provider: "slack", uid: "U01").user_id == ann.id

      general = Repo.get_by!(Chat.Channel, slug: "general")
      assert general.description == "Company-wide"
      assert Repo.get_by!(Chat.Channel, slug: "random").description == "Anything goes"

      assert Repo.aggregate(
               from(m in Chat.Membership, where: m.channel_id == ^general.id),
               :count
             ) == 2

      [welcome, reply, deploy] =
        Repo.all(
          from(m in Chat.Message, where: m.channel_id == ^general.id, order_by: m.inserted_at)
        )

      upload = Repo.get_by!(Upload, chat_message_id: welcome.id)

      assert welcome.body ==
               "Welcome **everyone**! Ask @ben.k about [the site](https://example.com) & *more*\n\n" <>
                 "![logo.png](/uploads/#{upload.token}/logo.png)"

      assert welcome.user_id == ann.id
      assert welcome.inserted_at == ~N[2020-01-01 11:00:00.000200]
      assert reply.thread_id == welcome.thread_id
      assert reply.thread_id
      assert reply.edited_at
      assert deploy.body == "Deployed ~~v1~~ v2"
      assert Repo.get!(User, deploy.user_id).username == "deploybot"
      assert Repo.get_by!(Chat.Reaction, message_id: welcome.id).emoji == "tada"

      conversation = Repo.one!(Conversation) |> Repo.preload([:messages, :participants])
      assert Enum.map(conversation.messages, & &1.body) == ["Hi Ben", "Hi Ann"]
      assert conversation.title == "ann, ben.k"
      refute Repo.exists?(Thread)
    end

    test "imports channels as categories and topics", %{zip: zip} do
      assert {:ok, _run} = FireflyImport.run("slack", path: zip, as: "forum", skip_after: true)
      general = Repo.get_by!(Category, title: "general")
      assert general.description == "Company-wide"

      welcome =
        Repo.get_by!(Thread, title: "Welcome everyone! Ask @ben.k about the site & more")
        |> Repo.preload(:posts)

      assert welcome.category_id == general.id
      assert Enum.map(welcome.posts, & &1.body) |> List.last() == "Thanks!"
      [first | _] = welcome.posts
      assert Repo.exists?(from(l in PostLike, where: l.post_id == ^first.id))

      day = Repo.get_by!(Thread, title: "general on 2020-01-02") |> Repo.preload(:posts)
      assert Enum.map(day.posts, & &1.body) == ["Deployed ~~v1~~ v2"]
      refute Repo.exists?(Chat.Message)
      refute Repo.exists?(Upload)
    end

    test "converts Slack's formatting" do
      assert Slack.to_markdown(
               "*b* _i_ ~s~ <!here> <mailto:a@b.c|mail> snake_case_name a*b*c",
               %{}
             ) ==
               "**b** *i* ~~s~~ @here [mail](mailto:a@b.c) snake_case_name a*b*c"
    end

    test "needs a readable export" do
      assert {:error, run} = FireflyImport.run("slack", path: "/nonexistent.zip")
      assert run.error == "/nonexistent.zip doesn't exist"

      assert {:error, run} =
               FireflyImport.run("slack", path: Path.join(@fixtures, "slack"), as: "wiki")

      assert run.error =~ "--as must be chat or forum"
    end
  end

  describe "Discord" do
    test "imports channels as chat, threads under their first message" do
      assert {:ok, _run} =
               FireflyImport.run("discord",
                 path: Path.join(@fixtures, "discord"),
                 skip_after: true
               )

      ann = Repo.get_by!(User, username: "ann")
      assert ann.name == "Ann"
      assert Repo.get_by!(UserIdentity, provider: "discord", uid: "7").user_id == ann.id

      general = Repo.get_by!(Chat.Channel, slug: "general")
      assert general.description == "Say hi"
      refute Repo.get_by(Chat.Channel, slug: "welcome-thread")

      [hello, reply, in_thread, beep] =
        Repo.all(
          from(m in Chat.Message, where: m.channel_id == ^general.id, order_by: m.inserted_at)
        )

      logo = Repo.get_by!(Upload, chat_message_id: hello.id)
      assert hello.body == "Hello **all**\n\n![logo.png](/uploads/#{logo.token}/logo.png)"
      assert reply.body == "Hi Ann"
      assert reply.edited_at
      assert in_thread.body == "In the thread"
      assert in_thread.thread_id == hello.thread_id
      assert in_thread.thread_id
      assert Repo.get!(User, beep.user_id).username == "botty"
      assert Repo.get_by!(Chat.Reaction, message_id: hello.id).emoji == "thumbsup"
      assert Repo.get_by!(Chat.Channel, slug: "help")
    end

    test "imports Discord's categories, channels and threads as a forum" do
      assert {:ok, _run} =
               FireflyImport.run("discord",
                 path: Path.join(@fixtures, "discord"),
                 as: "forum",
                 skip_after: true
               )

      community = Repo.get_by!(Category, title: "Community")
      general = Repo.get_by!(Category, title: "general")
      assert general.parent_id == community.id

      assert Repo.get_by!(Category, title: "help").parent_id ==
               Repo.get_by!(Category, title: "Support").id

      thread = Repo.get_by!(Thread, title: "Welcome thread") |> Repo.preload(:posts)
      assert thread.category_id == general.id
      assert Enum.map(thread.posts, & &1.body) |> List.last() == "In the thread"
      assert hd(thread.posts).body =~ "Hello **all**"

      day = Repo.get_by!(Thread, title: "general on 2021-05-01") |> Repo.preload(:posts)
      assert Enum.map(day.posts, & &1.body) == ["Hi Ann", "Beep"]
      assert Repo.aggregate(PostLike, :count) == 1
    end
  end

  describe "GitHub Discussions" do
    setup do
      url =
        FakeProvider.start(fn conn ->
          body = conn.assigns.body

          cond do
            Plug.Conn.get_req_header(conn, "authorization") != ["Bearer ghp_test"] ->
              FakeProvider.json(conn, 401, %{"message" => "Bad credentials"})

            body["variables"]["name"] != "repo" ->
              FakeProvider.json(conn, 200, %{
                "errors" => [%{"message" => "Could not resolve to a Repository"}]
              })

            true ->
              FakeProvider.json(conn, 200, github_page(body["variables"]["cursor"]))
          end
        end)

      {:ok, url: url <> "/graphql"}
    end

    test "imports categories, discussions, comments, replies, reactions and answers", %{url: url} do
      linked = Firefly.Fixtures.user_fixture(%{username: "octo"})

      Repo.insert!(%UserIdentity{user_id: linked.id, provider: "github", uid: "1"})

      assert {:ok, run} =
               FireflyImport.run("github",
                 repo: "owner/repo",
                 token: "ghp_test",
                 api_url: url,
                 skip_after: true
               )

      assert run.counts["topics"] == %{"imported" => 2}

      # Matched by their GitHub account, or made placeholders with it.
      refute Repo.get_by(User, username: "octocat")
      hubber = Repo.get_by!(User, username: "hubber")
      assert hubber.email == "hubber@example.com"
      assert Repo.get_by!(UserIdentity, provider: "github", uid: "2").user_id == hubber.id

      qa = Repo.get_by!(Category, title: "Q&A")
      assert qa.allow_accepted_answers
      refute Repo.get_by!(Category, title: "General").allow_accepted_answers

      question = Repo.get_by!(Thread, title: "How do I start?") |> Repo.preload(:posts)
      assert question.category_id == qa.id
      [body, comment, reply] = question.posts
      assert body.user_id == linked.id
      assert body.body == "I'm *new*."
      assert comment.body == "Run `mix setup`."
      assert reply.body == "Thanks!"
      assert question.accepted_post_id == comment.id

      assert Repo.exists?(
               from(l in PostLike, where: l.post_id == ^comment.id and l.user_id == ^linked.id)
             )

      closed = Repo.get_by!(Thread, title: "Old news")
      assert closed.closed_at
      assert Repo.get!(User, Repo.get_by!(Post, thread_id: closed.id).user_id).username == "ghost"
    end

    test "says why it can't read the discussions", %{url: url} do
      assert {:error, run} =
               FireflyImport.run("github", repo: "owner/other", token: "ghp_test", api_url: url)

      assert run.error == "GitHub: Could not resolve to a Repository"

      assert {:error, run} =
               FireflyImport.run("github", repo: "owner/repo", token: "wrong", api_url: url)

      assert run.error == "GitHub answered with HTTP 401"
      assert {:error, run} = FireflyImport.run("github", repo: "nope", token: "t", api_url: url)
      assert run.error == "--repo must be owner/name"
    end
  end

  defp person(login, id, email \\ nil),
    do: %{"login" => login, "databaseId" => id, "email" => email, "name" => nil}

  # Two pages of discussions.
  defp github_page(cursor) do
    categories = [
      %{"id" => "C1", "name" => "General", "description" => "", "isAnswerable" => false},
      %{"id" => "C2", "name" => "Q&A", "description" => "Ask", "isAnswerable" => true}
    ]

    {discussions, page_info} =
      case cursor do
        nil ->
          {[
             %{
               "id" => "D1",
               "number" => 1,
               "title" => "How do I start?",
               "body" => "I'm *new*.",
               "createdAt" => "2022-01-01T10:00:00Z",
               "updatedAt" => "2022-01-02T10:00:00Z",
               "lastEditedAt" => nil,
               "closed" => false,
               "locked" => false,
               "category" => %{"id" => "C2"},
               "answer" => %{"id" => "DC1"},
               "author" => person("octocat", 1),
               "reactions" => %{"nodes" => []},
               "comments" => %{
                 "nodes" => [
                   %{
                     "id" => "DC1",
                     "body" => "Run `mix setup`.",
                     "createdAt" => "2022-01-01T11:00:00Z",
                     "lastEditedAt" => nil,
                     "author" => person("hubber", 2, "hubber@example.com"),
                     "reactions" => %{
                       "nodes" => [
                         %{"user" => person("octocat", 1)},
                         %{"user" => person("octocat", 1)}
                       ]
                     },
                     "replies" => %{
                       "nodes" => [
                         %{
                           "id" => "DR1",
                           "body" => "Thanks!",
                           "createdAt" => "2022-01-01T12:00:00Z",
                           "lastEditedAt" => nil,
                           "author" => person("octocat", 1),
                           "reactions" => %{"nodes" => []}
                         }
                       ]
                     }
                   }
                 ]
               }
             }
           ], %{"hasNextPage" => true, "endCursor" => "page2"}}

        "page2" ->
          {[
             %{
               "id" => "D2",
               "number" => 2,
               "title" => "Old news",
               "body" => "Gone author",
               "createdAt" => "2021-01-01T10:00:00Z",
               "updatedAt" => "2021-01-01T10:00:00Z",
               "lastEditedAt" => nil,
               "closed" => true,
               "locked" => false,
               "category" => %{"id" => "C1"},
               "answer" => nil,
               "author" => nil,
               "reactions" => %{"nodes" => []},
               "comments" => %{"nodes" => []}
             }
           ], %{"hasNextPage" => false, "endCursor" => nil}}
      end

    %{
      "data" => %{
        "repository" => %{
          "discussionCategories" => %{"nodes" => categories},
          "discussions" => %{"pageInfo" => page_info, "nodes" => discussions}
        }
      }
    }
  end
end
