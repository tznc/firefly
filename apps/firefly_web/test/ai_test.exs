defmodule FireflyWeb.AITest do
  use FireflyWeb.ConnCase

  alias Firefly.{AI, Repo}
  alias Firefly.AI.{FakeProvider, ProviderConfig, Usage}

  setup do
    %{admin: admin_fixture()}
  end

  test "admins add, test, edit and delete providers", %{conn: conn, admin: admin} do
    url = FakeProvider.start_openai("connection works")

    session =
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/ai")
      |> assert_has("#ai-status", text: "AI is off")
      |> within("#provider-form", fn session ->
        session
        |> fill_in("Name", with: "Local")
        |> select("API", option: "OpenAI-compatible")
        |> fill_in("Base URL", with: url, exact: false)
        |> fill_in("Model id", with: "llama")
        |> check("Allow private addresses", exact: false)
        |> click_button("Add provider")
      end)
      |> assert_has("#ai-providers", text: "Local")
      |> assert_has("#ai-providers", text: "No key")

    provider = Repo.get_by!(ProviderConfig, name: "Local")
    assert provider.base_url == url and provider.allow_private

    session =
      session
      |> click_button("#provider-#{provider.id} button", "Test connection")
      |> assert_has("#test-#{provider.id}", text: "connection works", timeout: 2_000)
      |> assert_has("#test-#{provider.id} [data-ai-generated]")
      |> click_button("#provider-#{provider.id} button", "Edit")
      |> within("#provider-form", fn session ->
        session
        |> fill_in("API key", with: "sk-new", exact: false)
        |> click_button("Save provider")
      end)
      |> assert_has("#ai-providers", text: "Key set")

    assert AI.get_provider(provider.id).api_key == "sk-new"

    session
    |> click_button("#provider-#{provider.id} button", "Delete")
    |> refute_has("#ai-providers li")
  end

  test "admins switch AI and features on", %{conn: conn, admin: admin} do
    provider = FakeProvider.provider_fixture("http://127.0.0.1:1", %{"name" => "Main"})

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/ai")
    |> click_button("Turn AI on")
    |> assert_has("#ai-status", text: "AI is on")
    |> within("#feature-summarize", fn session ->
      session
      |> select("Provider", option: "Main")
      |> check("On")
      |> check("Staff only")
      |> click_button("Save")
    end)
    |> assert_has("[role=alert]", text: "Summaries saved.")

    assert %{enabled: true, staff_only: true} = AI.feature_settings()["summarize"]
    assert AI.feature_settings()["summarize"].provider_id == provider.id
    assert AI.enabled?()
  end

  test "the usage log and its report", %{conn: conn, admin: admin} do
    member = user_fixture()
    :ok = Usage.record("translate", member.id, %{input_tokens: 321, output_tokens: 45})

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/ai")
    |> assert_has("#ai-usage td", text: "@" <> member.username)
    |> assert_has("#ai-usage td", text: "321")
    |> visit(~p"/staff/reports/ai_usage")
    |> assert_has("h1", text: "AI usage")
  end

  test "only admins manage AI", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/ai")
    |> assert_path(~p"/")
  end

  test "the staff log shows provider changes", %{conn: conn, admin: admin} do
    {:ok, _} =
      AI.create_provider(%{"name" => "Logged", "adapter" => "anthropic", "model" => "m"}, admin)

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/log")
    |> assert_has("td", text: "Added AI provider")
    |> assert_has("a", text: "Logged")
  end

  test "settings validate long prompt overrides", %{admin: admin} do
    assert {:error, %{"ai_prompt_triage" => "must be at most 4000 characters"}} =
             Firefly.SiteSettings.update(
               %{"ai_prompt_triage" => String.duplicate("x", 4_001)},
               admin
             )
  end
end
