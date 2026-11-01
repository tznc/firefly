defmodule FirestormWeb.Web.NotificationSettingsTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Subscriptions

  test "turning email notifications off", %{conn: conn} do
    user = user_fixture()

    conn
    |> log_in_as(user)
    |> visit(~p"/notifications")
    |> click_link("Settings")
    |> assert_path(~p"/settings/notifications")
    |> uncheck("Email me about new posts in threads and categories I'm watching")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "Notification settings saved.")

    refute Forums.get_user!(user.id).email_notifications
  end

  test "setting a category's notification level", %{conn: conn} do
    user = user_fixture()
    category = category_fixture()

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{category}")
    |> assert_has("#category-level .level-label", text: "Normal")
    |> click_button("#category-level button", "Watching")
    |> assert_has("#category-level .level-label", text: "Watching")

    assert Subscriptions.category_level(user, category) == "watching"
  end

  test "a thread shows the level inherited from its category", %{conn: conn} do
    user = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, user_fixture())
    {:ok, _} = Subscriptions.set_category_level(user, category, "tracking")

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{category}/threads/#{thread}")
    |> assert_has("#thread-level .level-label", text: "Tracking")
  end

  test "requires a logged-in user", %{conn: conn} do
    conn |> visit(~p"/settings/notifications") |> assert_path(~p"/categories")
  end
end
