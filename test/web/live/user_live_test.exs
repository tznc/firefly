defmodule FirestormWeb.Web.UserLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  test "lists users", %{conn: conn} do
    user = user_fixture(%{username: "bob"})

    conn
    |> visit(~p"/")
    |> click_link("Users")
    |> assert_has("h1", text: "Users")
    |> assert_has("#user-#{user.id}", text: "bob")
  end

  test "paginates users", %{conn: conn} do
    for _ <- 1..11, do: user_fixture()

    conn
    |> visit(~p"/users")
    |> assert_has("#users li", count: 10)
    |> click_link("Next page")
    |> assert_path(~p"/users", query_params: %{page: "2"})
    |> assert_has("#users li", count: 1)
  end

  test "shows a user's profile and posts", %{conn: conn} do
    bob = user_fixture(%{username: "bob", name: "Bob Belcher"})
    category = category_fixture()
    thread_fixture(category, bob, %{title: "OTP is cool"})
    thread_fixture(category, bob, %{title: "GenStage"})

    conn
    |> visit(~p"/users/#{bob}")
    |> assert_has("h1", text: "bob")
    |> assert_has("p", text: "Bob Belcher")
    |> assert_has("dt", text: "Joined")
    |> assert_has("#user-posts article", count: 2)
  end

  test "avatars come from Gravatar", %{conn: conn} do
    bob = user_fixture(%{username: "bob", email: "bob@example.com"})

    conn
    |> visit(~p"/users/#{bob}")
    |> assert_has(~s(img[src^="https://secure.gravatar.com/avatar/"]))
  end

  describe "edit" do
    test "updates your own profile", %{conn: conn} do
      user = user_fixture()

      conn
      |> log_in_as(user)
      |> visit(~p"/users/#{user}")
      |> click_link("Edit")
      |> fill_in("Name", with: "some updated name")
      |> fill_in("Username", with: "updated")
      |> click_button("Save")
      |> assert_has("#flash-info", text: "User updated successfully.")
      |> assert_has("p", text: "some updated name")
    end

    test "shows errors for invalid data", %{conn: conn} do
      user = user_fixture()

      conn
      |> log_in_as(user)
      |> visit(~p"/users/#{user}/edit")
      |> fill_in("Username", with: "")
      |> click_button("Save")
      |> assert_has("p", text: "can't be blank")
    end

    test "can't change your API token", %{conn: conn} do
      user = user_fixture()

      conn
      |> log_in_as(user)
      |> visit(~p"/users/#{user}/edit")
      |> unwrap(fn view ->
        Phoenix.LiveViewTest.render_submit(view, "save_profile", %{
          "user" => %{"name" => "x", "api_token" => "chosen"}
        })
      end)

      assert Forums.get_user!(user.id).api_token == user.api_token
    end

    test "can't edit someone else", %{conn: conn} do
      me = user_fixture()
      them = user_fixture()

      conn
      |> log_in_as(me)
      |> visit(~p"/users/#{them}/edit")
      |> assert_path(~p"/users/#{them}")
      |> assert_has("#flash-error", text: "You can only edit your own profile.")
    end
  end
end
