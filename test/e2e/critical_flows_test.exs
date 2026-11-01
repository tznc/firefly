defmodule FirestormWeb.E2E.CriticalFlowsTest do
  use FirestormWeb.E2ECase, async: false

  alias FirestormWeb.Forums

  test "a new member registers, logs out and logs back in", %{conn: conn} do
    conn
    |> log_in("newbie")
    |> assert_has("nav a", text: "Your profile")
    |> click_link("Log out")
    |> assert_has("#flash-info", text: "You have been logged out!")
    |> assert_has("nav a", text: "Log in")
    |> log_in("newbie")
    |> refute_has("nav a", text: "Log in")
  end

  test "a wrong password is rejected", %{conn: conn} do
    member_fixture("alice")

    conn
    |> visit("/auth/identity")
    |> fill_in("Username", with: "alice")
    |> fill_in("Password", with: "not-the-password")
    |> click_button("Log in or register")
    |> assert_has("#flash-error", text: "No user found with that username or password")
    |> assert_path("/auth/identity")
  end

  test "a member creates a category and starts a thread with a live preview", %{conn: conn} do
    member_fixture("alice")

    conn
    |> log_in("alice")
    |> visit("/categories")
    |> click_link("New Category")
    |> fill_in("Title", with: "Elixir")
    |> click_button("Create Category")
    |> assert_has("#flash-info", text: "Category created successfully.")
    |> click_link("New Thread")
    |> fill_in("Title", with: "OTP is cool")
    |> fill_in("Body", with: "**Supervisors** all the way down :fire:")
    |> assert_has("#post-preview strong", text: "Supervisors")
    |> assert_has("#post-preview", text: "🔥")
    |> click_button("Create Thread")
    |> assert_has("#flash-info", text: "Thread created successfully.")
    |> assert_has("h1", text: "OTP is cool")
    |> assert_has("#posts article strong", text: "Supervisors")
  end

  test "a reply appears live for someone already reading the thread", %{conn: conn} = context do
    alice = member_fixture("alice")
    member_fixture("bob")
    category = Forums.create_category(%{title: "Elixir"}) |> elem(1)

    {:ok, thread} =
      Forums.create_thread(category, alice, %{title: "OTP is cool", body: "Don't you think?"})

    thread_path = "/categories/#{category.id}/threads/#{thread.id}"

    reader =
      conn
      |> visit(thread_path)
      |> assert_has("#reply-count", text: "0 replies")

    another_browser(context)
    |> log_in("bob")
    |> visit(thread_path)
    |> click_link("a.btn-primary", "Reply")
    |> fill_in("Body", with: "Totally agree!")
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created successfully.")

    # The reader's page updates without a reload.
    reader
    |> assert_has("#posts article", text: "Totally agree!")
    |> assert_has("#reply-count", text: "1 reply")
  end

  test "watching a thread notifies the watcher about new replies", %{conn: conn} = context do
    start_supervised!(FirestormWeb.Notifications)
    alice = member_fixture("alice")
    member_fixture("bob")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})

    {:ok, thread} =
      Forums.create_thread(category, alice, %{title: "GenStage", body: "Kinda streamy no?"})

    thread_path = "/categories/#{category.id}/threads/#{thread.id}"

    watcher =
      conn
      |> log_in("alice")
      |> visit(thread_path)
      |> click_button("watch")
      |> assert_has("button[aria-label='unwatch']")

    another_browser(context)
    |> log_in("bob")
    |> visit(thread_path <> "/posts/new")
    |> fill_in("Body", with: "Herp Derp")
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created successfully.")

    watcher
    |> visit("/notifications")
    |> assert_has("#notifications li", text: "There was a new post in thread: GenStage")
    |> click_link("There was a new post in thread: GenStage")
    |> assert_has("p", text: "Herp Derp")
  end

  test "admins manage categories in the admin UI; members can't reach it",
       %{conn: conn} = context do
    admin_fixture("root")
    member_fixture("alice")
    {:ok, _} = Forums.create_category(%{title: "Elixir"})

    conn
    |> log_in("root")
    |> click_link("Admin")
    |> visit("/admin/forums/category")
    |> assert_has("td", text: "Elixir")

    another_browser(context)
    |> log_in("alice")
    |> refute_has("nav a", text: "Admin")
    |> visit("/admin")
    |> assert_path("/")
    |> assert_has("#flash-error", text: "You must be an administrator to access this page.")
  end
end
