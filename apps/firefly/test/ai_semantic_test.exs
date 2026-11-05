defmodule Firefly.AISemanticTest do
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Accounts, AI, Discussion, Groups, SiteSettings}
  alias Firefly.AI.{Embeddings, FakeProvider, MCP, PostEmbedding, SemanticSearch}
  alias Firefly.Discussion.Search

  setup do
    admin = admin_fixture(%{username: "boss"})
    %{admin: admin, alice: member("alice"), category: category_fixture("Pets")}
  end

  defp member(username) do
    {:ok, user} = Accounts.confirm_user(user_fixture(%{username: username}))
    Repo.update!(Ecto.Changeset.change(user, trust_level: 1))
  end

  # Embeds by topic: cats, dogs, or anything else.
  defp vector(text) do
    cond do
      text =~ ~r/cat|kitten|feline/i -> [1.0, 0.1, 0.1]
      text =~ ~r/dog|puppy/i -> [0.1, 1.0, 0.1]
      true -> [0.1, 0.1, 1.0]
    end
  end

  defp embeddings_provider(admin, attrs \\ %{}) do
    url =
      FakeProvider.start(fn conn ->
        data =
          conn.assigns.body["input"]
          |> Enum.with_index()
          |> Enum.map(fn {text, i} -> %{"index" => i, "embedding" => vector(text)} end)

        FakeProvider.json(conn, 200, %{"data" => data, "usage" => %{"prompt_tokens" => 3}})
      end)

    provider =
      FakeProvider.provider_fixture(url, Map.merge(%{"embedding_model" => "embed-1"}, attrs))

    :ok = FakeProvider.enable(provider, "embeddings", admin)
    provider
  end

  defp first_post(thread), do: hd(Repo.preload(thread, :posts, force: true).posts)
  defp embedding(post), do: Repo.get(PostEmbedding, post.id)

  describe "embeddings" do
    test "posts are embedded as they're published and edited, first posts with the title", ctx do
      embeddings_provider(ctx.admin)
      thread = thread_fixture(ctx.category, ctx.alice, %{title: "My kitten", body: "So small"})
      post = first_post(thread)

      assert %PostEmbedding{model: "embed-1"} = embedding(post)

      assert_received {:ai_request,
                       %{path: "/embeddings", body: %{"input" => ["My kitten\n\nSo small"]}}}

      {:ok, _} = Discussion.update_post(post, ctx.alice, %{body: "Actually a puppy"})
      assert_received {:ai_request, %{body: %{"input" => ["My kitten\n\nActually a puppy"]}}}
      assert [_] = Repo.all(PostEmbedding)
    end

    test "run_due backfills, and embeds again after an edit or a new model", ctx do
      a = thread_fixture(ctx.category, ctx.alice, %{title: "Cats", body: "Meow"})
      b = thread_fixture(ctx.category, ctx.alice, %{title: "Dogs", body: "Woof"})
      assert Embeddings.run_due() == 0

      provider = embeddings_provider(ctx.admin)
      assert Embeddings.run_due() == 2
      assert Embeddings.run_due() == 0

      Repo.update_all(where(Discussion.Post, id: ^first_post(a).id), set: [body: "Purr"])
      assert Embeddings.run_due() == 1

      {:ok, _} = AI.update_provider(provider, %{"embedding_model" => "embed-2"}, ctx.admin)
      assert Embeddings.run_due() == 2
      assert %PostEmbedding{model: "embed-2"} = embedding(first_post(b))
      assert [%{feature: "embeddings", user_id: nil}] = Repo.all(AI.Usage)
    end

    test "embeddings need a provider that can make them", ctx do
      provider = FakeProvider.provider_fixture("http://127.0.0.1:1", %{"adapter" => "anthropic"})

      assert {:error, changeset} =
               AI.update_feature(
                 "embeddings",
                 %{provider_id: provider.id, enabled: true},
                 ctx.admin
               )

      assert %{provider_id: ["this provider can't do embed"]} = errors_on(changeset)
    end
  end

  describe "hybrid search" do
    setup ctx do
      embeddings_provider(ctx.admin)
      {:ok, team} = Groups.create_role("team")
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})

      cats = thread_fixture(ctx.category, ctx.alice, %{title: "Feline friends", body: "Whiskers"})
      dogs = thread_fixture(ctx.category, ctx.alice, %{title: "Puppy school", body: "Sit"})
      hidden = thread_fixture(secret, ctx.admin, %{title: "Secret cat club", body: "Shh"})
      %{cats: cats, dogs: dogs, hidden: hidden}
    end

    test "finds posts by meaning as well as by words, fused", ctx do
      search = Search.parse("kitten")
      assert Search.run(search, ctx.alice).entries == []

      assert {:semantic, page} = SemanticSearch.run(search, ctx.alice)
      assert [first | _] = page.entries
      assert first.thread.id == ctx.cats.id
      refute Enum.any?(page.entries, &(&1.thread.id == ctx.hidden.id))

      # Staff may read the secret category: it's found for them.
      {:semantic, page} = SemanticSearch.run(search, ctx.admin)
      assert Enum.any?(page.entries, &(&1.thread.id == ctx.hidden.id))
    end

    test "keeps the filters, and is full-text search without terms", ctx do
      {:semantic, page} = SemanticSearch.run(Search.parse("kitten @nobody"), ctx.alice)
      assert page.entries == []

      assert {:full_text, _page} = SemanticSearch.run(Search.parse("category:pets"), ctx.alice)
    end

    test "related topics are the nearest ones the reader may read", ctx do
      more = thread_fixture(ctx.category, ctx.alice, %{title: "Cat food", body: "Tuna"})
      assert [first | _] = SemanticSearch.related(ctx.cats, ctx.alice)
      assert first.id == more.id
      ids = Enum.map(SemanticSearch.related(ctx.cats, ctx.alice), & &1.id)
      refute ctx.cats.id in ids
      refute ctx.hidden.id in ids
    end

    test "is off with the feature", ctx do
      {:ok, _} = SiteSettings.update(%{"ai_enabled" => "false"}, ctx.admin)
      assert {:full_text, _page} = SemanticSearch.run(Search.parse("kitten"), ctx.alice)
      assert SemanticSearch.related(ctx.cats, ctx.alice) == []
    end
  end

  test "reciprocal rank fusion favours posts high in both lists" do
    assert SemanticSearch.fuse([[1, 2, 3], [1, 3, 4]]) == [1, 3, 2, 4]
  end

  describe "MCP" do
    defp rpc(user, method, params \\ %{}) do
      {:reply, response} =
        MCP.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}, user)

      response
    end

    defp call(user, tool, args),
      do: rpc(user, "tools/call", %{"name" => tool, "arguments" => args}).result

    test "initialize negotiates the version; tools are listed; notifications get no reply", ctx do
      assert %{result: %{protocolVersion: "2025-03-26", capabilities: %{tools: _}}} =
               rpc(ctx.alice, "initialize", %{"protocolVersion" => "2025-03-26"})

      assert %{result: %{protocolVersion: "2025-06-18"}} =
               rpc(ctx.alice, "initialize", %{"protocolVersion" => "1999-01-01"})

      assert %{result: %{tools: tools}} = rpc(ctx.alice, "tools/list")
      assert Enum.map(tools, & &1.name) == ~w(search read_topic list_latest get_user_profile)

      assert MCP.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, ctx.alice) ==
               :noreply

      assert %{error: %{code: -32_601}} = rpc(ctx.alice, "nope")
      assert {:reply, %{error: %{code: -32_600}}} = MCP.handle([1, 2], ctx.alice)
    end

    test "tools see only what the member may read", ctx do
      {:ok, team} = Groups.create_role("team")
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      open = thread_fixture(ctx.category, ctx.alice, %{title: "Open topic", body: "Hello world"})
      hidden = thread_fixture(secret, ctx.admin, %{title: "Hidden topic", body: "Hello world"})
      {:ok, _} = Discussion.create_post(open, ctx.admin, %{body: "A reply"})

      assert %{isError: false, structuredContent: %{results: results}} =
               call(ctx.alice, "search", %{"query" => "hello"})

      assert Enum.map(results, & &1.topic_id) == [open.id]

      assert %{
               isError: false,
               structuredContent: %{title: "Open topic", posts: [_, %{body: "A reply"}]}
             } =
               call(ctx.alice, "read_topic", %{"topic_id" => open.id})

      assert %{isError: true} = call(ctx.alice, "read_topic", %{"topic_id" => hidden.id})

      assert %{isError: false} =
               call(ctx.admin, "read_topic", %{"topic_id" => to_string(hidden.id)})

      assert %{structuredContent: %{topics: topics}} =
               call(ctx.alice, "list_latest", %{"limit" => 10})

      assert open.id in Enum.map(topics, & &1.topic_id)
      refute hidden.id in Enum.map(topics, & &1.topic_id)

      assert %{structuredContent: %{username: "alice", stats: _}} =
               call(ctx.alice, "get_user_profile", %{"username" => "ALICE"})

      Repo.update!(Ecto.Changeset.change(ctx.admin, hide_profile: true))

      assert %{structuredContent: profile} =
               call(ctx.alice, "get_user_profile", %{"username" => "boss"})

      refute Map.has_key?(profile, :stats)

      assert %{error: %{code: -32_602}} =
               rpc(ctx.alice, "tools/call", %{"name" => "delete_everything"})
    end
  end
end
