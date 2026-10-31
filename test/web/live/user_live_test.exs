defmodule FirestormWeb.Web.UserLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  test "lists users", %{conn: conn} do
    user = user_fixture(%{username: "bob"})
    {:ok, view, html} = live(conn, ~p"/users")

    assert html =~ "Users"
    assert has_element?(view, "#user-#{user.id}", "bob")
  end

  test "paginates users", %{conn: conn} do
    for _ <- 1..11, do: user_fixture()
    {:ok, view, _html} = live(conn, ~p"/users")

    assert has_element?(view, ~s(a[href="/users?page=2"]))
    view |> element(~s(a[href="/users?page=2"]), "2") |> render_click()
    assert_patch(view, ~p"/users?page=2")
    assert view |> element("#users") |> render() =~ "user-"
  end

  test "shows a user's profile and posts", %{conn: conn} do
    bob = user_fixture(%{username: "bob", name: "Bob Belcher"})
    category = category_fixture()
    thread_fixture(category, bob, %{title: "OTP is cool"})
    thread_fixture(category, bob, %{title: "GenStage"})

    {:ok, view, html} = live(conn, ~p"/users/#{bob}")

    assert html =~ "Bob Belcher"
    assert html =~ "Joined"
    assert view |> element("#user-posts") |> render() |> String.split("<article") |> length() == 3
  end

  describe "edit" do
    test "updates your own profile", %{conn: conn} do
      user = user_fixture()
      conn = log_in_as(conn, user)
      {:ok, view, _html} = live(conn, ~p"/users/#{user}/edit")

      {:ok, _show, html} =
        view
        |> form("#user-form", user: %{name: "some updated name", username: "updated"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "User updated successfully."
      assert html =~ "some updated name"
    end

    test "shows errors for invalid data", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/users/#{user}/edit")

      assert view |> form("#user-form", user: %{username: "", name: ""}) |> render_submit() =~
               "can&#39;t be blank"
    end

    test "can't change your API token", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = live(log_in_as(conn, user), ~p"/users/#{user}/edit")

      render_submit(view, "save", %{"user" => %{"name" => "x", "api_token" => "chosen"}})

      assert Forums.get_user!(user.id).api_token == user.api_token
    end

    test "can't edit someone else", %{conn: conn} do
      me = user_fixture()
      them = user_fixture()

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(log_in_as(conn, me), ~p"/users/#{them}/edit")

      assert to == ~p"/users/#{them}"
      assert flash["error"] == "You can only edit your own profile."
    end
  end
end
