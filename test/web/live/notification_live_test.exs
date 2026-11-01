defmodule FirestormWeb.Web.NotificationLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Notification

  setup do
    bob = user_fixture(%{username: "bob"})
    fred = user_fixture(%{username: "fred"})
    category = category_fixture()
    thread = thread_fixture(category, bob, %{title: "GenStage", body: "Kinda streamy no?"})
    {:ok, post} = Forums.create_post(thread, fred, %{body: "Herp Derp"})

    {:ok, notification} =
      Forums.notify(bob, Notification.thread_new_post_notification(thread, post))

    {:ok, bob: bob, fred: fred, notification: notification}
  end

  test "lists your notifications, with a count in the nav", %{conn: conn, bob: bob} do
    conn
    |> log_in_as(bob)
    |> visit(~p"/notifications")
    |> assert_has("#notifications li", text: "There was a new post in thread: GenStage")
    |> assert_has(~s{a[aria-label="Notifications (1)"]})
  end

  test "shows a notification", %{conn: conn, bob: bob, notification: notification} do
    conn
    |> log_in_as(bob)
    |> visit(~p"/notifications")
    |> click_link("There was a new post in thread: GenStage")
    |> assert_has("p", text: "Herp Derp")
    |> assert_has(~s(a[href="#{notification.url}"]), text: "Visit")
  end

  test "can't show someone else's notification", %{
    conn: conn,
    fred: fred,
    notification: notification
  } do
    conn
    |> log_in_as(fred)
    |> visit(~p"/notifications/#{notification}")
    |> assert_path(~p"/notifications")
    |> assert_has("#flash-error", text: "Notification not found.")
  end

  test "requires a logged-in user", %{conn: conn} do
    conn |> visit(~p"/notifications") |> assert_path(~p"/categories")
  end
end
