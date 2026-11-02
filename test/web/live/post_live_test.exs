defmodule FirestormWeb.Web.PostLiveTest do
  use FirestormWeb.Web.ConnCase

  setup %{conn: conn} do
    category = category_fixture()
    user = user_fixture(%{username: "knewter"})
    thread = thread_fixture(category, user)
    {:ok, conn: log_in_as(conn, user), category: category, thread: thread}
  end

  test "replying to a thread", %{conn: conn, category: category, thread: thread} do
    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}")
    |> click_link("a.btn-primary", "Reply")
    |> fill_in("Body", with: "I agree!")
    |> click_button("Reply")
    |> assert_path(~p"/categories/#{category}/threads/#{thread}")
    |> assert_has("#flash-info", text: "Post created successfully.")
    |> assert_has("#posts article", text: "I agree!")
    |> assert_has("#reply-count", text: "1 reply")
  end

  test "an empty reply shows an error instead of crashing", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}/posts/new")
    |> click_button("Reply")
    |> assert_has("p", text: "can't be blank")
  end

  test "previews the markdown", %{conn: conn, category: category, thread: thread} do
    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}/posts/new")
    |> fill_in("Body", with: "# Heading")
    |> assert_has("#post-preview h1", text: "Heading")
  end

  @tag :tmp_dir
  test "uploading an attachment appends a markdown image to the body", %{
    conn: conn,
    category: category,
    thread: thread,
    tmp_dir: tmp_dir
  } do
    path = FirestormWeb.UploadHelpers.image_file(tmp_dir, "cat.png")

    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}/posts/new")
    |> fill_in("Body", with: "Look:")
    |> upload("Attach files", path)
    |> assert_has("textarea", text: "Look:")
    |> assert_has("textarea", text: "![cat.png](/uploads/")
    |> assert_has("textarea", text: "/cat.png)")
  end

  @tag :tmp_dir
  test "a file that isn't what it claims is refused", %{
    conn: conn,
    category: category,
    thread: thread,
    tmp_dir: tmp_dir
  } do
    path = FirestormWeb.UploadHelpers.file(tmp_dir, "cat.png", "<script>alert(1)</script>")

    conn
    |> visit(~p"/categories/#{category}/threads/#{thread}/posts/new")
    |> upload("Attach files", path)
    |> assert_has("#flash-error", text: "That file type isn't allowed.")
    |> refute_has("textarea", text: "/uploads/")
  end

  test "sends visitors away with an error", %{category: category, thread: thread} do
    build_conn()
    |> visit(~p"/categories/#{category}/threads/#{thread}/posts/new")
    |> assert_path(~p"/categories")
    |> assert_has("#flash-error", text: "You must be logged in to access this page.")
  end
end
