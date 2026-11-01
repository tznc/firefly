defmodule FirestormWeb.Web.ThreadLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    category = category_fixture("Elixir")
    user = user_fixture(%{username: "knewter"})
    {:ok, category: category, user: user}
  end

  describe "recent (home page)" do
    test "lists threads across categories", %{conn: conn, category: category, user: user} do
      thread_fixture(category, user, %{title: "OTP is cool"})
      thread_fixture(category_fixture("Elm"), user, %{title: "Elm is neat"})

      conn
      |> visit(~p"/")
      |> assert_has(".thread-title", text: "OTP is cool")
      |> assert_has(".thread-title", text: "Elm is neat")
    end

    test "updates when a thread gets a new post", %{conn: conn, category: category, user: user} do
      session = visit(conn, ~p"/")
      thread = thread_fixture(category, user, %{title: "Fresh"})
      assert_has(session, ".thread-title", text: "Fresh")

      {:ok, _} = Forums.create_post(thread, user, %{body: "bump"})
      assert_has(session, "#thread-#{thread.id} .posts-count", text: "2")
    end
  end

  describe "new" do
    test "creates a thread", %{conn: conn, category: category, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}")
      |> click_link("New Thread")
      |> fill_in("Title", with: "OTP is cool")
      |> fill_in("Body", with: "Don't you think?")
      |> click_button("Create Thread")
      |> assert_has("#flash-info", text: "Thread created successfully.")
      |> assert_has("h1", text: "OTP is cool")
      |> assert_has("#posts article", text: "Don't you think?")
    end

    test "shows title and body errors", %{conn: conn, category: category, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}/threads/new")
      |> click_button("Create Thread")
      |> assert_has("p", text: "can't be blank", count: 2)

      assert Forums.list_threads(category) == []
    end

    test "previews the markdown as you type", %{conn: conn, category: category, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}/threads/new")
      |> fill_in("Body", with: "**bold** :fire:")
      |> assert_has("#post-preview strong", text: "bold")
      |> assert_has("#post-preview", text: "🔥")
    end

    test "sends visitors away with an error", %{conn: conn, category: category} do
      conn
      |> visit(~p"/categories/#{category}")
      |> click_link("New Thread")
      |> assert_path(~p"/categories")
      |> assert_has("#flash-error", text: "You must be logged in to access this page.")
    end
  end

  describe "show" do
    test "shows the thread, its posts and their authors", %{
      conn: conn,
      category: category,
      user: user
    } do
      thread = thread_fixture(category, user)
      {:ok, _} = Forums.create_post(thread, user_fixture(%{username: "bob"}), %{body: "I agree!"})

      conn
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> assert_has("h1", text: "OTP is cool")
      |> assert_has("#posts article", text: "Don't you think?")
      |> assert_has("#posts article", text: "I agree!")
      |> assert_has("#posts .username", text: "@bob")
      |> assert_has("#reply-count", text: "1 reply")
    end

    test "shows new posts without a reload", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      session = visit(conn, ~p"/categories/#{category}/threads/#{thread}")

      {:ok, post} = Forums.create_post(thread, user, %{body: "Live reply"})

      assert_has(session, "#post-#{post.id}", text: "Live reply")
    end

    test "setting the thread's notification level", %{conn: conn, category: category} do
      reader = user_fixture()
      thread = thread_fixture(category, user_fixture())

      session =
        conn
        |> log_in_as(reader)
        |> visit(~p"/categories/#{category}/threads/#{thread}")
        |> assert_has("#thread-level .level-label", text: "Normal")
        |> click_button("#thread-level button", "Watching")
        |> assert_has("#thread-level .level-label", text: "Watching")

      assert Forums.watched_by?(thread, reader)

      session
      |> click_button("#thread-level button", "Muted")
      |> assert_has("#thread-level .level-label", text: "Muted")

      refute Forums.watched_by?(thread, reader)
    end

    test "visitors don't get a notification level", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      conn
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> refute_has("#thread-level")
    end

    test "renders oEmbeds for links in posts", %{conn: conn, category: category, user: user} do
      url = "https://www.youtube.com/watch?v=H686MDn4Lo8"
      LruCache.put(:oembed_cache, url, %OEmbed.Video{html: "lolno"})

      thread =
        thread_fixture(category, user, %{body: "This is a cool video, check it out: #{url}"})

      conn
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> assert_has(~s([data-oembed-url="#{url}"]), text: "lolno")
    end

    test "a logged-in user can delete the thread", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> click_button("Delete")
      |> assert_path(~p"/categories/#{category}")
      |> assert_has("#flash-info", text: "Thread deleted successfully.")

      assert Forums.get_thread(thread.id) == nil
    end
  end

  describe "permissions" do
    test "other members can't edit or delete the thread", %{
      conn: conn,
      category: category,
      user: user
    } do
      thread = thread_fixture(category, user)
      other = log_in_as(conn, user_fixture())

      other
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> refute_has("button", text: "Delete")
      |> refute_has("a", text: "Edit")
      |> unwrap(&Phoenix.LiveViewTest.render_click(&1, "delete", %{}))

      assert Forums.get_thread(thread.id)

      other
      |> visit(~p"/categories/#{category}/threads/#{thread}/edit")
      |> assert_path(~p"/categories/#{category}/threads/#{thread}")
      |> assert_has("#flash-error", text: "You are not allowed to do that.")
    end

    test "admins can edit and delete anyone's thread", %{
      conn: conn,
      category: category,
      user: user
    } do
      thread = thread_fixture(category, user)

      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> click_link("Edit")
      |> fill_in("Title", with: "Moderated")
      |> click_button("Submit")
      |> assert_has("h1", text: "Moderated")
      |> click_button("Delete")
      |> assert_has("#flash-info", text: "Thread deleted successfully.")
    end
  end

  describe "edit" do
    test "renames the thread", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}/threads/#{thread}")
      |> click_link("Edit")
      |> fill_in("Title", with: "OTP is great")
      |> click_button("Submit")
      |> assert_has("#flash-info", text: "Thread updated successfully.")
      |> assert_has("h1", text: "OTP is great")
    end

    test "shows errors for an empty title", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}/threads/#{thread}/edit")
      |> fill_in("Title", with: "")
      |> click_button("Submit")
      |> assert_has("p", text: "can't be blank")
    end
  end

  describe "index" do
    test "lists the category's threads", %{conn: conn, category: category, user: user} do
      thread_fixture(category, user)

      conn
      |> visit(~p"/categories/#{category}/threads")
      |> assert_has("h1", text: "Listing Threads")
      |> assert_has("#threads td", text: "OTP is cool")
    end

    test "the author can delete their thread", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{category}/threads")
      |> within("#thread-#{thread.id}", &click_link(&1, "Delete"))
      |> assert_has("#flash-info", text: "Thread deleted successfully.")
      |> refute_has("#thread-#{thread.id}")
    end

    test "only shows edit and delete to the author", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      conn
      |> visit(~p"/categories/#{category}/threads")
      |> refute_has("#thread-#{thread.id} a", text: "Delete")

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/categories/#{category}/threads")
      |> refute_has("#thread-#{thread.id} a", text: "Delete")
      |> refute_has("#thread-#{thread.id} a", text: "Edit")
    end

    test "refuses a forged delete event from another member", %{
      conn: conn,
      category: category,
      user: user
    } do
      thread = thread_fixture(category, user)

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/categories/#{category}/threads")
      |> unwrap(&Phoenix.LiveViewTest.render_click(&1, "delete", %{"id" => thread.id}))

      assert Forums.get_thread(thread.id)
    end
  end

  describe "watching and participating" do
    test "list the user's threads", %{conn: conn, category: category, user: user} do
      watched = thread_fixture(category, user_fixture(), %{title: "Watched one"})
      {:ok, _} = Forums.watch(user, watched)
      thread_fixture(category, user, %{title: "My own"})
      conn = log_in_as(conn, user)

      conn
      |> visit(~p"/")
      |> click_link("Watching")
      |> assert_has(".thread-title", text: "Watched one")
      # Threads you start are watched automatically
      |> assert_has(".thread-title", text: "My own")
      |> click_link("Participating in")
      |> assert_has(".thread-title", text: "My own")
      |> refute_has(".thread-title", text: "Watched one")
    end

    test "require a logged-in user", %{conn: conn} do
      conn |> visit(~p"/threads/watching") |> assert_path(~p"/categories")
      conn |> visit(~p"/threads/participating") |> assert_path(~p"/categories")
    end
  end
end
