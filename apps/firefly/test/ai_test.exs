defmodule Firefly.AITest do
  use Firefly.DataCase

  alias Firefly.{AI, Reports, SiteSettings}
  alias Firefly.AI.{Adapters, Encrypted, FakeProvider, ProviderConfig, Usage}
  alias Firefly.Moderation.StaffAction

  import Firefly.Fixtures
  import ExUnit.CaptureLog

  setup do
    %{admin: admin_fixture()}
  end

  defp member(trust_level) do
    user = user_fixture()
    Repo.update!(Ecto.Changeset.change(user, trust_level: trust_level))
  end

  defp say(text), do: [%{role: :user, content: text}]

  describe "providers" do
    test "API keys are encrypted at rest and never logged", %{admin: admin} do
      {:ok, provider} =
        AI.create_provider(
          %{"name" => "OpenAI", "adapter" => "openai", "model" => "m", "api_key" => "sk-secret"},
          admin
        )

      assert provider.base_url == "https://api.openai.com/v1"
      assert AI.get_provider(provider.id).api_key == "sk-secret"

      %{rows: [[stored]]} =
        Repo.query!("SELECT api_key FROM ai_providers WHERE id = $1", [provider.id])

      refute stored =~ "sk-secret"
      assert Encrypted.decrypt(stored) == "sk-secret"

      [entry] = Repo.all(where(StaffAction, action: "ai_provider.create"))
      assert entry.details["api_key"] == "changed"
      refute inspect(entry.details) =~ "sk-secret"
    end

    test "a key from another secret reads as nil" do
      stored = Encrypted.encrypt("sk-secret")
      Application.put_env(:firefly, Firefly.AI, retry_base_ms: 0, encryption_key: "another")
      on_exit(fn -> Application.put_env(:firefly, Firefly.AI, retry_base_ms: 0) end)
      assert Encrypted.decrypt(stored) == nil
    end

    test "a blank key keeps the stored one; clearing removes it", %{admin: admin} do
      provider = FakeProvider.provider_fixture("http://127.0.0.1:1")

      {:ok, provider} =
        AI.update_provider(provider, %{"model" => "other", "api_key" => ""}, admin)

      assert AI.get_provider(provider.id).api_key == "sk-test"
      {:ok, provider} = AI.update_provider(provider, %{"clear_api_key" => "true"}, admin)
      assert AI.get_provider(provider.id).api_key == nil
    end

    test "validates the adapter, URL and limits", %{admin: admin} do
      {:error, changeset} =
        AI.create_provider(
          %{
            "name" => "X",
            "adapter" => "nope",
            "model" => "m",
            "base_url" => "ftp://x",
            "max_tokens" => "0"
          },
          admin
        )

      assert %{adapter: _, base_url: _, max_tokens: _} = errors_on(changeset)
    end

    test "test_provider reports the answer or the failure" do
      url = FakeProvider.start_openai("connection works")

      assert {:ok, %{text: "connection works"}} =
               AI.test_provider(FakeProvider.provider_fixture(url))

      url =
        FakeProvider.start(&FakeProvider.json(&1, 401, %{"error" => %{"message" => "bad key"}}))

      assert {:error, message} = AI.test_provider(FakeProvider.provider_fixture(url))
      assert message =~ "401" and message =~ "bad key"
    end

    test "deleting a provider turns its features off", %{admin: admin} do
      provider = FakeProvider.provider_fixture("http://127.0.0.1:1")
      :ok = FakeProvider.enable(provider, "summarize", admin)
      :ok = AI.delete_provider(provider, admin)
      refute AI.feature_settings()["summarize"].enabled
      refute AI.available?(admin, "summarize")
    end
  end

  describe "the OpenAI-compatible adapter" do
    test "sends the model, system prompt and key, and reads the answer and usage" do
      url = FakeProvider.start_openai("Hi there")
      provider = FakeProvider.provider_fixture(url)

      assert {:ok, %{text: "Hi there", usage: %{input_tokens: 12, output_tokens: 5}}} =
               Adapters.OpenAI.chat(say("Hello"),
                 provider: provider,
                 system: "Be brief.",
                 json: true
               )

      assert_received {:ai_request, %{path: "/chat/completions", headers: headers, body: body}}
      assert {"authorization", "Bearer sk-test"} in headers

      assert %{
               "model" => "test-model",
               "max_tokens" => 1024,
               "response_format" => %{"type" => "json_object"},
               "messages" => [
                 %{"role" => "system", "content" => "Be brief."},
                 %{"role" => "user", "content" => "Hello"}
               ]
             } = body
    end

    test "streams text as it arrives" do
      url =
        FakeProvider.start(fn conn ->
          FakeProvider.sse(conn, [
            {nil, %{"choices" => [%{"delta" => %{"content" => "Hel"}}]}},
            {nil, %{"choices" => [%{"delta" => %{"content" => "lo"}}]}},
            {nil,
             %{"choices" => [], "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}}},
            {nil, "[DONE]"}
          ])
        end)

      test = self()

      assert {:ok, %{text: "Hello", usage: %{input_tokens: 3, output_tokens: 2}}} =
               Adapters.OpenAI.chat(say("Hi"),
                 provider: FakeProvider.provider_fixture(url),
                 stream: &send(test, {:delta, &1})
               )

      assert_received {:delta, "Hel"}
      assert_received {:delta, "lo"}
      assert_received {:ai_request, %{body: %{"stream" => true}}}
    end

    test "embeds texts in order, with the embedding model" do
      url =
        FakeProvider.start(fn conn ->
          FakeProvider.json(conn, 200, %{
            "data" => [
              %{"index" => 1, "embedding" => [0.25, 1.0]},
              %{"index" => 0, "embedding" => [1.0, 0.25]}
            ],
            "usage" => %{"prompt_tokens" => 4}
          })
        end)

      provider = FakeProvider.provider_fixture(url, %{"embedding_model" => "embedder"})

      assert {:ok, %{vectors: [[1.0, 0.25], [0.25, 1.0]], usage: %{input_tokens: 4}}} =
               Adapters.OpenAI.embed(["a", "b"], provider: provider)

      assert_received {:ai_request, %{path: "/embeddings", body: %{"model" => "embedder"}}}
    end
  end

  describe "the Anthropic adapter" do
    test "sends the Messages API request and reads the answer" do
      url = FakeProvider.start(&FakeProvider.anthropic_reply(&1, "Bonjour"))
      provider = FakeProvider.provider_fixture(url, %{"adapter" => "anthropic"})

      assert {:ok, %{text: "Bonjour", usage: %{input_tokens: 10, output_tokens: 4}}} =
               Adapters.Anthropic.chat(say("Hello"), provider: provider, system: "Translate.")

      assert_received {:ai_request, %{path: "/v1/messages", headers: headers, body: body}}
      assert {"x-api-key", "sk-test"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers

      assert %{"model" => "test-model", "system" => "Translate.", "max_tokens" => 1024} = body
      assert Adapters.Anthropic.embed(["x"], provider: provider) |> elem(0) == :error
    end

    test "streams text and usage from the event stream" do
      url =
        FakeProvider.start(fn conn ->
          FakeProvider.sse(conn, [
            {"message_start",
             %{"type" => "message_start", "message" => %{"usage" => %{"input_tokens" => 7}}}},
            {"ping", %{"type" => "ping"}},
            {"content_block_delta",
             %{
               "type" => "content_block_delta",
               "delta" => %{"type" => "text_delta", "text" => "Sa"}
             }},
            {"content_block_delta",
             %{
               "type" => "content_block_delta",
               "delta" => %{"type" => "text_delta", "text" => "lut"}
             }},
            {"message_delta", %{"type" => "message_delta", "usage" => %{"output_tokens" => 3}}},
            {"message_stop", %{"type" => "message_stop"}}
          ])
        end)

      provider = FakeProvider.provider_fixture(url, %{"adapter" => "anthropic"})
      test = self()

      assert {:ok, %{text: "Salut", usage: %{input_tokens: 7, output_tokens: 3}}} =
               Adapters.Anthropic.chat(say("Hi"), provider: provider, stream: &send(test, &1))

      assert_received "Sa"
    end
  end

  describe "HTTP" do
    test "retries 429 and 5xx answers, not other errors" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      url =
        FakeProvider.start(fn conn ->
          case Agent.get_and_update(counter, &{&1, &1 + 1}) do
            0 -> FakeProvider.json(conn, 429, %{"error" => %{"message" => "slow down"}})
            1 -> FakeProvider.json(conn, 503, %{"error" => %{"message" => "overloaded"}})
            _ -> FakeProvider.openai_reply(conn, "finally")
          end
        end)

      assert {:ok, %{text: "finally"}} =
               Adapters.OpenAI.chat(say("Hi"), provider: FakeProvider.provider_fixture(url))

      assert Agent.get(counter, & &1) == 3

      url = FakeProvider.start(&FakeProvider.json(&1, 400, %{"error" => %{"message" => "bad"}}))

      assert {:error, "the provider answered 400: bad"} =
               Adapters.OpenAI.chat(say("Hi"), provider: FakeProvider.provider_fixture(url))

      assert_received {:ai_request, %{path: "/chat/completions"}}
      assert_received {:ai_request, _}
      assert_received {:ai_request, _}
      assert_received {:ai_request, _}
      refute_received {:ai_request, _}
    end

    test "gives up after two retries" do
      url = FakeProvider.start(&FakeProvider.json(&1, 500, %{"error" => "boom"}))

      assert {:error, "the provider answered 500: boom"} =
               Adapters.OpenAI.chat(say("Hi"), provider: FakeProvider.provider_fixture(url))
    end

    test "times out after the provider's timeout" do
      url =
        FakeProvider.start(fn conn ->
          Process.sleep(1_500)
          FakeProvider.openai_reply(conn, "late")
        end)

      provider = FakeProvider.provider_fixture(url, %{"timeout_seconds" => "1"})

      assert {:error, "the provider didn't answer within 1 seconds"} =
               Adapters.OpenAI.chat(say("Hi"), provider: provider)
    end

    test "refuses private addresses unless the provider allows them" do
      url = FakeProvider.start_openai("never")
      provider = FakeProvider.provider_fixture(url, %{"allow_private" => "false"})

      assert {:error, message} = Adapters.OpenAI.chat(say("Hi"), provider: provider)
      assert message =~ "private address"
      refute_received {:ai_request, _}
    end
  end

  describe "requests" do
    setup %{admin: admin} do
      url = FakeProvider.start_openai("A summary")
      provider = FakeProvider.provider_fixture(url)
      :ok = FakeProvider.enable(provider, ["summarize", "triage"], admin)
      %{provider: provider}
    end

    test "go to the feature's provider and are logged as usage", %{admin: admin} do
      user = member(1)
      assert {:ok, %{text: "A summary"}} = AI.chat(user, "summarize", say("Sum it up"))
      assert {:ok, _} = AI.chat(nil, "triage", say("Rate it"))

      assert [%{feature: "summarize", requests: 1, input_tokens: 12, output_tokens: 5}] =
               Repo.all(where(Usage, user_id: ^user.id))

      assert [%{feature: "triage"}] = Repo.all(from(u in Usage, where: is_nil(u.user_id)))
      assert AI.used_today(user) == 1
      assert AI.used_today(admin) == 0
    end

    test "are refused when AI or the feature is off", %{admin: admin} do
      user = member(1)
      assert {:error, :disabled} = AI.chat(user, "translate", say("x"))
      {:ok, _} = SiteSettings.update(%{"ai_enabled" => "false"}, admin)
      assert {:error, :disabled} = AI.chat(user, "summarize", say("x"))
      refute AI.available?(user, "summarize")
      refute_received {:ai_request, _}
    end

    test "need a member, except for system work" do
      assert {:error, :unauthenticated} = AI.chat(nil, "summarize", say("x"))
    end

    test "staff-only features are for admins", %{admin: admin, provider: provider} do
      :ok = FakeProvider.enable(provider, "summarize", admin, %{staff_only: true})
      assert {:error, :staff_only} = AI.chat(member(4), "summarize", say("x"))
      assert {:ok, _} = AI.chat(admin, "summarize", say("x"))
    end

    test "count against the daily quota for the member's trust level", %{admin: admin} do
      {:ok, _} =
        SiteSettings.update(%{"ai_daily_quota_tl0" => "0", "ai_daily_quota_tl2" => "2"}, admin)

      assert {:error, :quota} = AI.chat(member(0), "summarize", say("x"))

      regular = member(2)
      assert {:ok, _} = AI.chat(regular, "summarize", say("x"))
      assert {:ok, _} = AI.chat(regular, "summarize", say("x"))
      assert {:error, :quota} = AI.chat(regular, "summarize", say("x"))
      assert AI.quota(regular) == 2
      assert AI.quota(admin) == :unlimited
    end

    test "a provider's failure is logged, not shown", %{admin: admin} do
      url = FakeProvider.start(&FakeProvider.json(&1, 400, %{"error" => %{"message" => "no"}}))
      :ok = FakeProvider.enable(FakeProvider.provider_fixture(url), "summarize", admin)

      log =
        capture_log(fn ->
          assert {:error, :provider_failed} = AI.chat(admin, "summarize", say("x"))
        end)

      assert log =~ "failed for summarize"
      assert Repo.all(Usage) == []
    end
  end

  test "a feature needs a provider to be on", %{admin: admin} do
    assert {:error, changeset} = AI.update_feature("summarize", %{enabled: true}, admin)
    assert %{provider_id: ["pick a provider to turn the feature on"]} = errors_on(changeset)
    assert Repo.all(where(StaffAction, action: "ai_feature.update")) == []

    provider = FakeProvider.provider_fixture("http://127.0.0.1:1")
    {:ok, _} = AI.update_feature("summarize", %{provider_id: provider.id, enabled: true}, admin)

    assert [%{details: %{"feature" => "summarize", "provider" => name}}] =
             Repo.all(where(StaffAction, action: "ai_feature.update"))

    assert name == provider.name
  end

  test "json/1 finds the object in an answer" do
    assert AI.json("Sure:\n```json\n{\"spam\": 3}\n```") == {:ok, %{"spam" => 3}}
    assert AI.json("no json") == :error
  end

  test "the usage report sums tokens per day" do
    user = user_fixture()
    :ok = Usage.record("summarize", user.id, %{input_tokens: 100, output_tokens: 20})
    :ok = Usage.record("translate", nil, %{input_tokens: 5, output_tokens: 1})

    {:series, series} = Reports.get("ai_usage").run(Reports.last(7))
    totals = Map.new(series, &{&1.key, &1.points |> List.last() |> elem(1)})
    assert totals == %{"requests" => 2, "input" => 105, "output" => 21}
  end

  test "prompts can be overridden by a site setting", %{admin: admin} do
    assert AI.Prompts.render("translate", %{"language" => "French"}) =~ "into French"

    {:ok, _} =
      SiteSettings.update(%{"ai_prompt_translate" => "To {{language}} for {{site}}."}, admin)

    assert AI.Prompts.render("translate", %{"language" => "French"}) == "To French for Firefly."
  end

  test "a provider's adapter module" do
    assert ProviderConfig.module(%ProviderConfig{adapter: "anthropic"}) == Adapters.Anthropic
  end
end
