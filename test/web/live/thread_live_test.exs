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

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "OTP is cool"
      assert html =~ "Elm is neat"
    end

    test "updates when a thread gets a new post", %{conn: conn, category: category, user: user} do
      {:ok, view, _html} = live(conn, ~p"/")
      thread = thread_fixture(category, user, %{title: "Fresh"})

      assert render(view) =~ "Fresh"

      {:ok, _} = Forums.create_post(thread, user, %{body: "bump"})
      assert has_element?(view, "#thread-#{thread.id} .posts-count", "2")
    end
  end

  describe "new" do
    test "creates a thread", %{conn: conn, category: category, user: user} do
      conn = log_in_as(conn, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/new")

      {:ok, _show, html} =
        view
        |> form("#thread-form", thread: %{title: "OTP is cool", body: "Don't you think?"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Thread created successfully."
      assert html =~ "OTP is cool"
      assert html =~ "Don&#39;t you think?"
    end

    test "shows title and body errors", %{conn: conn, category: category, user: user} do
      conn = log_in_as(conn, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/new")

      html = view |> form("#thread-form", thread: %{title: "", body: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Forums.list_threads(category) == []
    end

    test "previews the markdown as you type", %{conn: conn, category: category, user: user} do
      conn = log_in_as(conn, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/new")

      view
      |> form("#thread-form", thread: %{title: "t", body: "**bold** :fire:"})
      |> render_change()

      assert has_element?(view, "#post-preview strong", "bold")
      assert render(view) =~ "🔥"
    end

    test "redirects visitors to log in", %{conn: conn, category: category} do
      assert {:error, {:redirect, %{to: "/categories", flash: flash}}} =
               live(conn, ~p"/categories/#{category}/threads/new")

      assert flash["error"] == "You must be logged in to access this page."
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

      {:ok, view, html} = live(conn, ~p"/categories/#{category}/threads/#{thread}")

      assert html =~ "OTP is cool"
      assert has_element?(view, "#posts article", "Don't you think?")
      assert has_element?(view, "#posts article", "I agree!")
      assert has_element?(view, "#posts .username", "@bob")
      assert has_element?(view, "#reply-count", "1 reply")
    end

    test "shows new posts without a reload", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}")

      {:ok, post} = Forums.create_post(thread, user, %{body: "Live reply"})

      assert has_element?(view, "#post-#{post.id}", "Live reply")
    end

    test "watching and unwatching", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      {:ok, view, _html} =
        live(log_in_as(conn, user), ~p"/categories/#{category}/threads/#{thread}")

      assert has_element?(view, "#watch")
      view |> element("#watch") |> render_click()
      assert has_element?(view, "#unwatch")
      assert Forums.watched_by?(thread, user)

      view |> element("#unwatch") |> render_click()
      assert has_element?(view, "#watch")
      refute Forums.watched_by?(thread, user)
    end

    test "visitors can't watch", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}")

      assert view |> element("#watch") |> render_click() =~
               "You must be logged in to access this page."
    end

    test "renders oEmbeds for links in posts", %{conn: conn, category: category, user: user} do
      url = "https://www.youtube.com/watch?v=H686MDn4Lo8"
      LruCache.put(:oembed_cache, url, %OEmbed.Video{html: "lolno"})

      thread =
        thread_fixture(category, user, %{body: "This is a cool video, check it out: #{url}"})

      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}")

      assert has_element?(view, ~s([data-oembed-url="#{url}"]), "lolno")
    end

    test "a logged-in user can delete the thread", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      conn = log_in_as(conn, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}")

      {:ok, _category_view, html} =
        view |> element("button", "Delete") |> render_click() |> follow_redirect(conn)

      assert html =~ "Thread deleted successfully."
      assert Forums.get_thread(thread.id) == nil
    end
  end

  describe "edit" do
    test "renames the thread", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      conn = log_in_as(conn, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}/edit")

      {:ok, _show, html} =
        view
        |> form("#thread-form", thread: %{title: "OTP is great"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Thread updated successfully."
      assert html =~ "OTP is great"
    end

    test "shows errors for an empty title", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)

      {:ok, view, _html} =
        live(log_in_as(conn, user), ~p"/categories/#{category}/threads/#{thread}/edit")

      assert view |> form("#thread-form", thread: %{title: ""}) |> render_submit() =~
               "can&#39;t be blank"
    end
  end

  describe "index" do
    test "lists the category's threads", %{conn: conn, category: category, user: user} do
      thread_fixture(category, user)
      {:ok, _view, html} = live(conn, ~p"/categories/#{category}/threads")

      assert html =~ "Listing Threads"
      assert html =~ "OTP is cool"
    end

    test "deletes a thread when logged in", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/categories/#{category}/threads")

      assert view |> element("#thread-#{thread.id} a", "Delete") |> render_click() =~
               "Thread deleted successfully."

      refute has_element?(view, "#thread-#{thread.id}")
    end

    test "visitors can't delete", %{conn: conn, category: category, user: user} do
      thread = thread_fixture(category, user)
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/threads")

      assert view |> element("#thread-#{thread.id} a", "Delete") |> render_click() =~
               "You must be logged in"

      assert Forums.get_thread(thread.id)
    end
  end

  describe "watching and participating" do
    test "list the user's threads", %{conn: conn, category: category, user: user} do
      watched = thread_fixture(category, user_fixture(), %{title: "Watched one"})
      {:ok, _} = Forums.watch(user, watched)
      mine = thread_fixture(category, user, %{title: "My own"})
      conn = log_in_as(conn, user)

      {:ok, _view, html} = live(conn, ~p"/threads/watching")
      assert html =~ "Watched one"
      refute html =~ "My own"

      {:ok, _view, html} = live(conn, ~p"/threads/participating")
      assert html =~ mine.title
      refute html =~ "Watched one"
    end

    test "require a logged-in user", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/categories"}}} = live(conn, ~p"/threads/watching")
      assert {:error, {:redirect, %{to: "/categories"}}} = live(conn, ~p"/threads/participating")
    end
  end
end
