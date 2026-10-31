defmodule FirestormWeb.Web.PostLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup %{conn: conn} do
    category = category_fixture()
    user = user_fixture(%{username: "knewter"})
    thread = thread_fixture(category, user)
    {:ok, conn: log_in_as(conn, user), category: category, thread: thread}
  end

  test "replying to a thread", %{conn: conn, category: category, thread: thread} do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}/posts/new")

    {:ok, show, html} =
      view
      |> form("#post-form", post: %{body: "I agree!"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Post created successfully."
    assert has_element?(show, "#posts article", "I agree!")
    assert has_element?(show, "#reply-count", "1 reply")
  end

  test "an empty reply shows an error instead of crashing", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}/posts/new")

    assert view |> form("#post-form", post: %{body: ""}) |> render_submit() =~
             "can&#39;t be blank"
  end

  test "previews the markdown", %{conn: conn, category: category, thread: thread} do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}/posts/new")

    view |> form("#post-form", post: %{body: "# Heading"}) |> render_change()

    assert has_element?(view, "#post-preview h1", "Heading")
  end

  test "uploading an attachment appends a markdown image to the body", %{
    conn: conn,
    category: category,
    thread: thread
  } do
    {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}/posts/new")
    view |> form("#post-form", post: %{body: "Look:"}) |> render_change()

    file =
      file_input(view, "#post-form", :attachment, [
        %{name: "cat.png", content: "fake png", type: "image/png"}
      ])

    render_upload(file, "cat.png")

    body = view |> element("#post-form textarea") |> render()
    assert body =~ "Look:"

    assert body =~
             ~r{!\[cat\.png\]\(https://s3-us-east-1\.amazonaws\.com/firestorm-test/uploads/[^/]+/cat\.png\)}
  end

  test "redirects visitors to log in", %{category: category, thread: thread} do
    assert {:error, {:redirect, %{to: "/categories"}}} =
             live(build_conn(), ~p"/categories/#{category}/threads/#{thread}/posts/new")
  end

  test "the posts count in the thread reflects the reply", %{category: category, thread: thread} do
    {:ok, _} = Forums.create_post(thread, user_fixture(), %{body: "another"})

    assert length(
             Forums.get_thread!(category, thread.id)
             |> FirestormWeb.Repo.preload(:posts)
             |> Map.get(:posts)
           ) == 2
  end
end
