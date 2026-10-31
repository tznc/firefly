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
      Forums.notify(
        bob,
        Notification.thread_new_post_notification(%{thread | category_id: category.id}, post)
      )

    {:ok, bob: bob, fred: fred, notification: notification}
  end

  test "lists your notifications, with a count in the nav", %{conn: conn, bob: bob} do
    {:ok, view, _html} = live(log_in_as(conn, bob), ~p"/notifications")

    assert has_element?(view, "#notifications li", "There was a new post in thread: GenStage")
    assert has_element?(view, ~s{a[aria-label="Notifications (1)"]})
  end

  test "shows a notification", %{conn: conn, bob: bob, notification: notification} do
    {:ok, view, html} = live(log_in_as(conn, bob), ~p"/notifications/#{notification}")

    assert html =~ "Herp Derp"
    assert has_element?(view, ~s(a[href="#{notification.url}"]), "Visit")
  end

  test "can't show someone else's notification", %{
    conn: conn,
    fred: fred,
    notification: notification
  } do
    assert {:error, {:live_redirect, %{to: "/notifications", flash: flash}}} =
             live(log_in_as(conn, fred), ~p"/notifications/#{notification}")

    assert flash["error"] == "Notification not found."
  end

  test "requires a logged-in user", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/categories"}}} = live(conn, ~p"/notifications")
  end
end
