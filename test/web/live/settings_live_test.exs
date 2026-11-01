defmodule FirestormWeb.Web.SettingsLiveTest do
  use FirestormWeb.Web.ConnCase

  import FirestormWeb.DataCase, only: [errors_on: 1]
  require Phoenix.LiveViewTest

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Subscriptions, User}

  setup do
    %{user: user_fixture(%{username: "ada"})}
  end

  test "the settings tabs, with the old URLs still working", %{conn: conn, user: user} do
    conn = log_in_as(conn, user)

    conn
    |> visit(~p"/settings")
    |> assert_has("#settings-tabs .tab-active", text: "Profile")
    |> click_link("#settings-tabs a", "Privacy")
    |> assert_path(~p"/settings/privacy")
    |> assert_has("#privacy-form")

    conn |> visit(~p"/users/#{user}/edit") |> assert_path(~p"/settings/profile")
    conn |> visit(~p"/settings/notifications") |> assert_has("#preferences-form")
    build_conn() |> visit(~p"/settings/privacy") |> assert_path(~p"/categories")
  end

  describe "profile" do
    test "bio, website and location show on the profile", %{conn: conn, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/settings/profile")
      |> fill_in("About me", with: "I write **Elixir**.")
      |> fill_in("Website", with: "https://ada.example/about")
      |> fill_in("Location", with: "London")
      |> click_button("Save")
      |> assert_path(~p"/users/#{user}")
      |> assert_has("#user-bio strong", text: "Elixir")
      |> assert_has("#user-website[href='https://ada.example/about']", text: "ada.example")
      |> assert_has("#user-location", text: "London")
    end

    test "are validated", %{conn: conn, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/settings/profile")
      |> fill_in("Website", with: "javascript:alert(1)")
      |> click_button("Save")
      |> assert_has("#profile-form", text: "must be a web address starting with http")

      too_long = String.duplicate("a", 1_001)
      assert {:error, changeset} = Forums.update_user(user, %{bio: too_long, location: too_long})

      assert %{bio: ["should be at most 1000 character(s)"], location: [_]} =
               errors_on(changeset)
    end
  end

  describe "interface" do
    test "the theme is saved and set by the root layout; visitors get the system default",
         %{conn: conn, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/settings/interface")
      |> select("Theme", option: "Dark")
      |> click_button("Save")
      |> assert_has("#flash-info", text: "Interface settings saved.")

      assert Forums.get_user!(user.id).theme == "dark"

      assert conn |> log_in_as(user) |> get(~p"/") |> html_response(200) =~
               ~s{data-user-theme="dark"}

      refute build_conn() |> get(~p"/") |> html_response(200) =~ "data-user-theme"
    end

    test "the top bar toggle saves the theme for users", %{conn: conn, user: user} do
      {:ok, view, _html} = conn |> log_in_as(user) |> Phoenix.LiveViewTest.live(~p"/")
      Phoenix.LiveViewTest.render_click(view, "set_theme", %{"theme" => "light"})
      assert Forums.get_user!(user.id).theme == "light"

      Phoenix.LiveViewTest.render_click(view, "set_theme", %{"theme" => "neon"})
      assert Forums.get_user!(user.id).theme == "light"
    end
  end

  test "notification levels for new threads and replies", %{conn: conn, user: user} do
    conn
    |> log_in_as(user)
    |> visit(~p"/settings/notifications")
    |> select("When I start a thread", option: "Tracking")
    |> select("When I reply to a thread", option: "Normal")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "Notification settings saved.")

    user = Forums.get_user!(user.id)
    category = category_fixture()
    mine = thread_fixture(category, user)
    theirs = thread_fixture(category, user_fixture())
    {:ok, _} = Forums.create_post(theirs, user, %{body: "Reply"})

    assert Subscriptions.thread_level(user, mine) == "tracking"
    # Normal sets nothing: the thread keeps what it inherits.
    assert Subscriptions.thread_level(user, theirs) == nil
    assert Subscriptions.effective_thread_level(user, theirs) == "normal"

    # The defaults: watch what you start, track what you reply to.
    other = user_fixture()
    {:ok, _} = Forums.create_post(mine, other, %{body: "Reply"})
    assert Subscriptions.thread_level(other, mine) == "tracking"
    assert Subscriptions.thread_level(other, thread_fixture(category, other)) == "watching"
  end

  test "preferences are validated", %{user: user} do
    assert {:error, changeset} =
             Forums.update_preferences(user, %{
               theme: "neon",
               reply_level: "watching",
               new_thread_level: "muted"
             })

    assert %{theme: [_], reply_level: [_], new_thread_level: [_]} = errors_on(changeset)
    assert User.preferences_changeset(user, %{theme: "dark"}).valid?
  end

  describe "privacy" do
    setup %{user: user} do
      thread_fixture(category_fixture(), user, %{title: "Ada's thread"})
      :ok
    end

    test "hiding activity hides posts from others, not from yourself or admins",
         %{conn: conn, user: user} do
      conn
      |> log_in_as(user)
      |> visit(~p"/settings/privacy")
      |> check("Hide my posts and activity from my profile (admins still see them)")
      |> click_button("Save")
      |> assert_has("#flash-info", text: "Privacy settings saved.")

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/users/#{user}")
      |> assert_has("#activity-hidden", text: "ada keeps their activity private.")
      |> refute_has("#user-posts")
      |> refute_has("dt", text: "Last post")

      build_conn() |> visit(~p"/users/#{user}") |> refute_has("#user-posts")

      conn
      |> log_in_as(user)
      |> visit(~p"/users/#{user}")
      |> assert_has("#user-posts", text: "Ada's thread")

      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/users/#{user}")
      |> assert_has("#user-posts", text: "Ada's thread")
    end

    test "hiding from the directory", %{conn: conn, user: user} do
      conn |> visit(~p"/users") |> assert_has("#user-#{user.id}")
      {:ok, _} = Forums.update_preferences(user, %{hide_from_directory: true})
      conn |> visit(~p"/users") |> refute_has("#user-#{user.id}")
      conn |> visit(~p"/users/#{user}") |> assert_has("h1", text: "ada")
    end
  end
end
