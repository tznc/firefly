defmodule FireflyWeb.E2E.KeyboardTest do
  @moduledoc """
  The keyboard shortcuts (see the `KeyboardShortcuts` hook) and the
  keyboard paths through the page: the skip link and the help modal.
  """
  use FireflyWeb.E2ECase, async: false

  alias Firefly.{Accounts, Discussion}

  setup do
    member = member_fixture("bob")
    {:ok, category} = Discussion.create_category(%{title: "Elixir"})

    {:ok, thread} =
      Discussion.create_thread(category, member, %{title: "OTP is cool", body: "Don't you think?"})

    {:ok, _} = Discussion.create_post(thread, member, %{body: "A reply"})
    %{member: member, category: category, thread: thread}
  end

  test "? opens the shortcuts help, Escape closes it", %{conn: conn} do
    conn
    |> log_in("bob")
    |> assert_has("[data-phx-main].phx-connected")
    |> press("?")
    |> assert_has("#shortcuts-help[open] h2", text: "Keyboard shortcuts")
    |> evaluate("document.getElementById('shortcuts-help').matches(':modal')", &assert(&1))
    |> press("Escape")
    |> refute_has("#shortcuts-help[open]")
  end

  test "j and k move through the topics, g c goes to the categories", %{
    conn: conn,
    thread: thread
  } do
    conn
    |> log_in("bob")
    |> assert_has("[data-phx-main].phx-connected")
    |> press("j")
    |> evaluate("document.activeElement.id", &assert(&1 == "thread-#{thread.id}"))
    |> press("k")
    |> evaluate("document.activeElement.id", &assert(&1 == "thread-#{thread.id}"))
    |> press("g")
    |> press("c")
    |> assert_path("/categories")
  end

  test "l likes the post in hand and b bookmarks it", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    [_first, reply] = Firefly.Repo.preload(thread, :posts, force: true).posts
    member_fixture("ada")

    session =
      conn
      |> log_in("ada")
      |> visit("/categories/#{category.id}/threads/#{thread.id}")
      |> assert_has("[data-phx-main].phx-connected")
      # The first post is the author's own, so j twice reaches the reply.
      |> press("j")
      |> press("j")
      |> press("l")
      |> assert_has("#post-#{reply.id} .like-count", text: "1")

    session
    |> press("b")
    |> assert_has("#bookmark-form")
  end

  test "typing in the composer is never a shortcut", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    conn
    |> log_in("bob")
    |> visit("/categories/#{category.id}/threads/#{thread.id}/posts/new")
    |> assert_has("[data-phx-main].phx-connected")
    |> fill_in("Body", with: "jk? l and b, / too")
    |> refute_has("#shortcuts-help[open]")
    |> assert_has("#post-preview", text: "jk? l and b, / too")
  end

  test "a member can turn the shortcuts off", %{conn: conn, member: member} do
    {:ok, _user} = Accounts.update_preferences(member, %{keyboard_shortcuts: false})

    conn
    |> log_in("bob")
    |> assert_has("[data-phx-main].phx-connected")
    |> press("?")
    |> refute_has("#shortcuts-help[open]")
  end

  test "the skip link jumps to the content", %{conn: conn} do
    conn
    |> visit("/")
    |> assert_has("[data-phx-main].phx-connected")
    |> press("Tab")
    |> evaluate("document.activeElement.className", &assert(&1 =~ "skip-link"))
    |> press("Enter")
    |> evaluate("window.location.hash", &assert(&1 == "#main"))
  end

  # Sends a key to the page: the shortcuts listen on the window, so the
  # body is as good a target as any (and is where focus starts).
  defp press(session, key), do: PhoenixTest.Playwright.press(session, "body", key)
end
