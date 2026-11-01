defmodule FirestormWeb.E2E.CriticalFlowsTest do
  use FirestormWeb.E2ECase, async: false

  alias FirestormWeb.Forums

  test "a new member registers, logs out and logs back in", %{conn: conn} do
    conn
    |> visit("/login")
    |> click_link("Create Account")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Email", with: "newbie@example.com")
    |> fill_in("Password", with: "s3cret-password")
    |> click_button("Create account")
    |> assert_has("#flash-info", text: "Successfully authenticated.")
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
    |> click_button("Log in")
    |> assert_has("#flash-error", text: "No user found with that username or password")
    |> assert_path("/auth/identity")
  end

  test "an admin creates a category and starts a thread with a live preview", %{conn: conn} do
    admin_fixture("alice")

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

  test "watching a thread notifies the watcher live about new replies", %{conn: conn} = context do
    start_supervised!(FirestormWeb.Notifications)
    alice = member_fixture("alice")
    member_fixture("bob")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})

    {:ok, thread} =
      Forums.create_thread(category, alice, %{title: "GenStage", body: "Kinda streamy no?"})

    thread_path = "/categories/#{category.id}/threads/#{thread.id}"

    watcher =
      conn
      |> log_in("bob")
      |> visit(thread_path)
      |> click_button("#thread-level [role=button]", "Normal")
      |> click_button("#thread-level li button", "Watching")
      |> assert_has("#thread-level .level-label", text: "Watching")
      |> visit("/")
      |> assert_has("a[aria-label='Notifications (0)']")

    another_browser(context)
    |> log_in("alice")
    |> visit(thread_path <> "/posts/new")
    |> fill_in("Body", with: "Herp Derp")
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created successfully.")

    # The badge updates without a reload
    watcher
    |> assert_has("a[aria-label='Notifications (1)']")
    |> visit("/notifications")
    |> click_button("#notifications button", "@alice replied in")
    |> assert_has("p", text: "Herp Derp")
    |> assert_has("a[aria-label='Notifications (0)']")
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

  test "selecting text in a post and clicking Quote quotes just the selection", %{conn: conn} do
    alice = member_fixture("alice")
    member_fixture("bob")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})

    {:ok, thread} =
      Forums.create_thread(category, alice, %{
        title: "Supervision",
        body: "Let it crash. Supervisors restart children for you."
      })

    [post] = thread.posts
    thread_path = "/categories/#{category.id}/threads/#{thread.id}"

    conn
    |> log_in("bob")
    |> visit(thread_path)
    |> assert_has("#post-#{post.id}-body", text: "Supervisors restart")
    |> PhoenixTest.Playwright.evaluate("""
    (() => {
      const text = document.querySelector("#post-#{post.id}-body p").firstChild
      const start = text.textContent.indexOf("Supervisors restart")
      const range = document.createRange()
      range.setStart(text, start)
      range.setEnd(text, start + "Supervisors restart children".length)
      window.getSelection().removeAllRanges()
      window.getSelection().addRange(range)
    })()
    """)
    |> PhoenixTest.Playwright.click("#post-#{post.id}-quote")
    |> assert_path(thread_path <> "/posts/new")
    |> assert_has("textarea", text: "> Supervisors restart children")
    |> refute_has("textarea", text: "Let it crash")
    |> assert_has("#post-preview .quote-attribution", text: "@alice said:")
    |> fill_in("Body", with: "Quoting works", exact: false)
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created successfully.")
  end

  test "typing @ in the editor suggests users to mention", %{conn: conn} do
    alice = member_fixture("alice")
    member_fixture("bob")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})
    {:ok, thread} = Forums.create_thread(category, alice, %{title: "Hello", body: "Hi all"})

    conn
    |> log_in("bob")
    |> visit("/categories/#{category.id}/threads/#{thread.id}/posts/new")
    |> PhoenixTest.Playwright.type("#post_body", "Thanks @ali")
    |> assert_has("#post_body-mentions [role=option]", text: "@alice")
    |> PhoenixTest.Playwright.press("#post_body", "Enter")
    |> refute_has("#post_body-mentions [role=option]")
    |> assert_has("#post-preview a[href$='/users/#{alice.id}']", text: "@alice")
    |> click_button("Reply")
    |> assert_has("#posts article a[href$='/users/#{alice.id}']", text: "@alice")
  end

  test "a reply draft survives leaving the page straight after typing", %{conn: conn} do
    alice = member_fixture("alice")
    category = Forums.create_category(%{title: "Elixir"}) |> elem(1)
    {:ok, thread} = Forums.create_thread(category, alice, %{title: "OTP", body: "Thoughts?"})
    reply_path = "/categories/#{category.id}/threads/#{thread.id}/posts/new"

    conn
    |> log_in("alice")
    |> visit(reply_path)
    |> assert_has("[data-phx-main].phx-connected")
    # Typed, then away at once: within the autosave debounce, so the draft
    # is only saved because leaving the field flushes it.
    |> PhoenixTest.Playwright.type("#post_body", "Not finished yet")
    |> click_link("nav a", "Latest")
    |> assert_path("/")
    |> visit(reply_path)
    |> assert_has("#draft-status", text: "Draft saved")
    |> assert_has("#post_body", text: "Not finished yet")
    |> click_link("nav a", "Drafts")
    |> assert_has("#drafts li", text: "Reply to OTP")
  end
end
