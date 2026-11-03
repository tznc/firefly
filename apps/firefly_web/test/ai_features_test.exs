defmodule FireflyWeb.AIFeaturesTest do
  use FireflyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Firefly.{Accounts, Chat, Discussion, Repo, SiteSettings}
  alias Firefly.AI.FakeProvider

  setup do
    admin = admin_fixture(%{username: "boss"})
    %{admin: admin, alice: member("alice"), bob: member("bob"), category: category_fixture()}
  end

  defp member(username) do
    {:ok, user} = Accounts.confirm_user(user_fixture(%{username: username}))
    Repo.update!(Ecto.Changeset.change(user, trust_level: 1))
  end

  defp provider(admin, features, answer) do
    url =
      FakeProvider.start(fn conn ->
        text = if is_function(answer, 1), do: answer.(conn.assigns.body), else: answer
        FakeProvider.openai_reply(conn, text)
      end)

    :ok = FakeProvider.enable(FakeProvider.provider_fixture(url), features, admin)
  end

  defp long_thread(ctx) do
    {:ok, _} = SiteSettings.update(%{"ai_summary_min_posts" => "2"}, ctx.admin)
    thread = thread_fixture(ctx.category, ctx.alice, %{title: "Long one", body: "Opening"})
    {:ok, _} = Discussion.create_post(thread, ctx.bob, %{body: "A reply"})
    thread
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "a long topic's summary, labelled, streamed and then cached", ctx do
    provider(ctx.admin, "summarize", "**Everyone agrees**")
    thread = long_thread(ctx)

    view = ctx.conn |> log_in_as(ctx.bob) |> live(thread_path(thread)) |> elem(1)
    view |> element("#summarize") |> render_click()
    render_async(view)

    assert has_element?(view, "#summary [data-ai-generated]")
    assert has_element?(view, "#summary-body strong", "Everyone agrees")
  end

  test "no summary button for short topics, visitors, or with the feature off", ctx do
    thread = long_thread(ctx)

    ctx.conn |> log_in_as(ctx.bob) |> visit(thread_path(thread)) |> refute_has("#summarize")

    provider(ctx.admin, "summarize", "x")
    ctx.conn |> visit(thread_path(thread)) |> refute_has("#summarize")

    short = thread_fixture(ctx.category, ctx.alice)
    ctx.conn |> log_in_as(ctx.bob) |> visit(thread_path(short)) |> refute_has("#summarize")
  end

  test "translating a post", ctx do
    provider(ctx.admin, "translate", "Bonjour tout le monde")
    thread = thread_fixture(ctx.category, ctx.alice, %{body: "Hello everyone"})
    post = hd(Repo.preload(thread, :posts).posts)

    view = ctx.conn |> log_in_as(ctx.bob) |> live(thread_path(thread)) |> elem(1)
    view |> element("[aria-label='Translate post #{post.id}']") |> render_click()
    render_async(view)

    assert has_element?(view, "#translation-#{post.id} [data-ai-generated]")
    assert has_element?(view, "#translation-#{post.id}-body", "Bonjour tout le monde")
  end

  test "chat: summarize the channel and translate a message", ctx do
    provider(ctx.admin, ["summarize", "translate"], fn body ->
      if hd(body["messages"])["content"] =~ "Translate", do: "Salut", else: "Bob says hi"
    end)

    {:ok, general} = Chat.create_channel(%{"name" => "General"}, ctx.admin)
    :ok = Chat.follow(general, ctx.alice)
    {:ok, message} = Chat.send_message(general, ctx.bob, %{"body" => "Hi all"})

    view =
      ctx.conn
      |> log_in_as(ctx.alice)
      |> live(~p"/chat/c/#{general.slug}/#{general.id}")
      |> elem(1)

    view |> element("#summarize-channel") |> render_click()
    render_async(view)
    assert has_element?(view, "#chat-ai-body", "Bob says hi")
    assert has_element?(view, "#chat-ai [data-ai-generated]")

    view |> element("button[phx-click=translate][phx-value-id='#{message.id}']") |> render_click()
    render_async(view)
    assert has_element?(view, "#chat-ai-body", "Salut")
  end

  test "composer helpers suggest, and change the draft only when picked", ctx do
    provider(ctx.admin, "composer", fn body ->
      case hd(body["messages"])["content"] do
        "Proofread" <> _ -> "The text, fixed."
        "Suggest" <> _ -> "A good title"
        _tags -> ~s({"tags": ["elixir"]})
      end
    end)

    {:ok, view, _html} =
      ctx.conn |> log_in_as(ctx.alice) |> live(~p"/categories/#{ctx.category}/threads/new")

    view |> form("#thread-form", thread: %{body: "teh text"}) |> render_change()

    view |> element("button[phx-value-helper=proofread]") |> render_click()
    render_async(view)
    assert has_element?(view, "#ai-suggestion", "The text, fixed.")
    assert has_element?(view, "#ai-suggestion [data-ai-generated]")
    assert has_element?(view, "textarea", "teh text")

    view |> element("button", "Use this") |> render_click()
    assert has_element?(view, "textarea", "The text, fixed.")
    refute has_element?(view, "#ai-suggestion")

    view |> element("button[phx-value-helper=title]") |> render_click()
    render_async(view)
    view |> element("button", "Use this") |> render_click()
    assert has_element?(view, "input[name='thread[title]'][value='A good title']")

    view |> element("button[phx-value-helper=tags]") |> render_click()
    render_async(view)
    view |> element("button", "Use this") |> render_click()
    assert has_element?(view, "input[name='thread[tags]'][value='elixir']")
  end

  test "no composer helpers when they're off", ctx do
    ctx.conn
    |> log_in_as(ctx.alice)
    |> visit(~p"/categories/#{ctx.category}/threads/new")
    |> refute_has("#ai-helpers")
  end

  test "the dashboard shows sentiment once triage is on", ctx do
    ctx.conn
    |> log_in_as(ctx.admin)
    |> visit(~p"/staff/dashboard")
    |> refute_has("h2", text: "Sentiment")

    provider(ctx.admin, "triage", ~s({"toxicity": 0, "spam": 0, "sentiment": "positive"}))

    ctx.conn
    |> log_in_as(ctx.admin)
    |> visit(~p"/staff/dashboard")
    |> assert_has("h2", text: "Sentiment")
  end
end
