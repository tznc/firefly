defmodule FirestormWeb.Web.NotificationLiveTest do
  use FirestormWeb.Web.ConnCase

  require Phoenix.LiveViewTest

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

  test "opening a notification goes to the post and marks it read", %{
    conn: conn,
    bob: bob,
    notification: notification
  } do
    conn
    |> log_in_as(bob)
    |> visit(~p"/notifications")
    |> assert_has("#notification-#{notification.id}.unread")
    |> click_button("There was a new post in thread: GenStage")
    |> assert_has("h1", text: "GenStage")
    |> assert_has(~s{a[aria-label="Notifications (0)"]})

    assert Forums.get_notification(notification.id).read_at
  end

  test "the notification page still shows one, and marks it read", %{
    conn: conn,
    bob: bob,
    notification: notification
  } do
    conn
    |> log_in_as(bob)
    |> visit(~p"/notifications/#{notification}")
    |> assert_has("p", text: "Herp Derp")
    |> assert_has(~s(a[href="#{notification.url}"]), text: "Visit")

    assert Forums.get_notification(notification.id).read_at
  end

  test "mark all as read", %{conn: conn, bob: bob} do
    conn
    |> log_in_as(bob)
    |> visit(~p"/notifications")
    |> click_button("Mark all as read")
    |> refute_has("#notifications li.unread")
    |> assert_has(~s{a[aria-label="Notifications (0)"]})
  end

  test "the badge updates live when a notification arrives", %{conn: conn, bob: bob, fred: fred} do
    {:ok, view, _html} = Phoenix.LiveViewTest.live(log_in_as(conn, bob), ~p"/")
    assert Phoenix.LiveViewTest.render(view) =~ ~s{aria-label="Notifications (1)"}

    thread = thread_fixture(category_fixture("Other"), fred, %{title: "Live"})
    {:ok, post} = Forums.create_post(thread, fred, %{body: "ping"})
    {:ok, _} = Forums.notify(bob, Notification.for_post("new_post", thread, post, fred))

    assert Phoenix.LiveViewTest.render(view) =~ ~s{aria-label="Notifications (2)"}
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
