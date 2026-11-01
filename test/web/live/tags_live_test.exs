defmodule FirestormWeb.Web.TagsLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Subscriptions

  setup %{conn: conn} do
    author = user_fixture()
    %{conn: log_in_as(conn, author), author: author, category: category_fixture()}
  end

  test "tags are set when starting a thread and shown in lists and on the thread", %{
    conn: conn,
    category: category
  } do
    conn
    |> visit(~p"/categories/#{category}/threads/new")
    |> fill_in("Title", with: "Supervisors")
    |> fill_in("Tags", with: "OTP, a b c d e")
    |> fill_in("Body", with: "Let it crash")
    |> click_button("Create Thread")
    |> assert_has("#thread-form", text: "can have at most 5 tags")
    |> fill_in("Tags", with: "OTP, beam")
    |> click_button("Create Thread")
    |> assert_has("h1", text: "Supervisors")
    |> assert_has(".tags a.tag", text: "otp")
    |> visit(~p"/")
    |> assert_has("#threads .tags a.tag", text: "beam")
    |> click_link("#threads a.tag", "otp")
    |> assert_path(~p"/tags/otp")
    |> assert_has("#threads .thread-title", text: "Supervisors")
    |> click_link("All tags")
    |> assert_has("#tag-otp", text: "1")
  end

  test "the thread author edits the tags", %{conn: conn, author: author, category: category} do
    thread = thread_fixture(category, author, %{tags: "otp"})

    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}/edit")
    |> assert_has("input[name='thread[tags]'][value='otp']")
    |> fill_in("Tags", with: "otp, genserver")
    |> click_button("Submit")
    |> assert_has(".tags a.tag", text: "genserver")
  end

  test "the tag page sets the tag's notification level, and still lists a muted tag's threads", %{
    conn: conn,
    author: author,
    category: category
  } do
    # Someone else's thread: the author's own is watched, which beats the tag.
    thread = thread_fixture(category, user_fixture(), %{tags: "otp"})

    conn
    |> visit(~p"/tags/otp")
    |> click_button("#tag-level li button", "Muted")
    |> assert_has("#tag-level .level-label", text: "Muted")
    |> assert_has("#threads .thread-title", text: thread.title)

    assert Subscriptions.tag_level(author, Forums.get_tag!("otp")) == "muted"
    # Hidden from the cross-category lists, though
    refute thread.id in Enum.map(Forums.latest_threads(author), & &1.id)
  end
end
