defmodule FireflyWeb.AkismetTest do
  # Akismet's base URL is global.
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Accounts, Discussion, FakeAkismet, Messaging, Repo}
  alias Firefly.Discussion.Post

  setup do
    FakeAkismet.setup()
    admin = admin_fixture(%{username: "boss"})
    {:ok, alice} = Accounts.confirm_user(user_fixture(%{username: "alice"}))
    %{admin: admin, alice: alice}
  end

  test "staff confirm or clear Akismet's spam in the review queue", %{conn: conn} = ctx do
    thread = thread_fixture(category_fixture(), ctx.admin)
    {:ok, spam} = Discussion.create_post(thread, ctx.alice, %{body: "viagra deals"})
    {:ok, ham} = Discussion.create_post(thread, ctx.alice, %{body: "viagra, as a word"})

    {:ok, _} =
      Messaging.start_conversation(ctx.alice, %{
        "recipients" => "boss",
        "title" => "Hi",
        "body" => "viagra for you"
      })

    conn
    |> log_in_as(ctx.admin)
    |> visit(~p"/staff/review")
    |> assert_has("#flagged-#{spam.id} .flag", text: "Akismet: spam")
    |> click_button("#flagged-#{spam.id} button", "Confirm spam")
    |> assert_has("#flash-info", text: "Agreed: the post was deleted.")
    |> click_button("#flagged-#{ham.id} button", "Not spam")
    |> assert_has("#flash-info", text: "Disagreed: the post is shown again.")
    |> assert_has("#akismet article", text: "viagra for you")
    |> click_button("#akismet button", "Not spam")
    |> assert_has("#flash-info", text: "Marked not spam.")
    |> assert_has("#review-empty")

    assert_received {:akismet, "submit-spam", %{"comment_content" => "viagra deals"}}
    assert_received {:akismet, "submit-ham", %{"comment_content" => "viagra, as a word"}}
    assert_received {:akismet, "submit-ham", %{"comment_content" => "viagra for you"}}
    refute Post.hidden?(Repo.get!(Post, ham.id))
  end

  test "posting from the web records the client for Akismet", %{conn: conn} = ctx do
    thread = thread_fixture(category_fixture(), ctx.admin)

    conn
    |> Plug.Conn.put_req_header("user-agent", "TestBrowser/1.0")
    |> log_in_as(ctx.alice)
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread.id}/posts/new")
    |> fill_in("Body", with: "Hello from the web")
    |> click_button("Reply")

    assert_received {:akismet, "comment-check", params}
    assert params["user_ip"] == "127.0.0.1"
  end

  test "the report and the staff log show it", %{conn: conn} = ctx do
    thread = thread_fixture(category_fixture(), ctx.admin)
    {:ok, _} = Discussion.create_post(thread, ctx.alice, %{body: "viagra"})

    session = conn |> log_in_as(ctx.admin)
    session |> visit(~p"/staff/reports/akismet") |> assert_has("h1", text: "Akismet")
    session |> visit(~p"/staff/log") |> assert_has("td", text: "Akismet caught spam")
  end
end
