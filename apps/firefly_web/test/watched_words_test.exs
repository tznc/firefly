defmodule FireflyWeb.WatchedWordsTest do
  use FireflyWeb.ConnCase, async: false

  alias Firefly.Moderation.WatchedWords

  setup do
    on_exit(fn -> WatchedWords.put_cache(%{}) end)
    {:ok, admin: admin_fixture()}
  end

  test "admins add, test and remove words per action", %{conn: conn, admin: admin} do
    session =
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/watched-words")
      |> assert_has("#words-empty")
      |> click_link("#tab-replace", "Replace")
      |> fill_in("Word", with: "teh")
      |> fill_in("Replace with", with: "the")
      |> click_button("Add word")
      |> assert_has("#flash-info", text: "Now watching \"teh\".")
      |> assert_has("#watched-words li", text: "→ the")
      |> assert_has("#tab-replace .badge", text: "1")
      |> fill_in("Text to test", with: "Teh end")
      |> assert_has("#test-result", text: "Matches: teh")

    [word] = WatchedWords.list("replace")

    session
    |> click_button("#word-#{word.id} button", "Remove")
    |> assert_has("#flash-info", text: "Stopped watching \"teh\".")
    |> assert_has("#words-empty")
  end

  test "invalid words show errors", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/watched-words?action=link")
    |> fill_in("Word", with: "elixir")
    |> fill_in("Link to (URL)", with: "nope")
    |> click_button("Add word")
    |> assert_has("#watched-word-form", text: "must be an http(s) URL or a path on this site")
  end

  test "members can't manage them", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/watched-words")
    |> assert_path(~p"/")
  end

  test "censored words are masked in thread titles and posts", %{conn: conn, admin: admin} do
    {:ok, _} = WatchedWords.create(admin, %{"word" => "darn", "action" => "censor"})
    category = category_fixture()
    thread = thread_fixture(category, user_fixture(), %{title: "Darn it", body: "darn bugs"})

    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}")
    |> assert_has("h1", text: "■■■■ it")
    |> assert_has("article", text: "■■■■ bugs")
    |> refute_has("article", text: "darn")
  end

  test "a blocked word is refused when posting", %{conn: conn, admin: admin} do
    {:ok, _} = WatchedWords.create(admin, %{"word" => "casino", "action" => "block"})
    category = category_fixture()

    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/categories/#{category}/threads/new")
    |> fill_in("Title", with: "Hello")
    |> fill_in("Body", with: "Best casino")
    |> click_button("Create Thread")
    |> assert_has("form", text: "contains a word that's not allowed: casino")
  end
end
