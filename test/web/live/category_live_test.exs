defmodule FirestormWeb.Web.CategoryLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  describe "index" do
    test "lists categories", %{conn: conn} do
      category_fixture("Elixir")
      category_fixture("Elm")

      conn
      |> visit(~p"/categories")
      |> assert_has("h1", text: "Categories")
      |> assert_has("#categories li", text: "Elixir")
      |> assert_has("#categories li", text: "Elm")
    end

    test "shows categories created elsewhere without a reload", %{conn: conn} do
      session = conn |> visit(~p"/categories") |> refute_has("#categories", text: "Erlang")

      category_fixture("Erlang")

      assert_has(session, "#categories li", text: "Erlang")
    end
  end

  describe "new" do
    test "sends visitors away with an error", %{conn: conn} do
      conn
      |> visit(~p"/categories")
      |> refute_has("a", text: "New Category")
      |> visit(~p"/categories/new")
      |> assert_path(~p"/categories")
      |> assert_has("#flash-error", text: "You must be logged in to access this page.")
    end

    test "is for admins only", %{conn: conn} do
      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/categories")
      |> refute_has("a", text: "New Category")
      |> visit(~p"/categories/new")
      |> assert_path(~p"/categories")
      |> assert_has("#flash-error", text: "You are not allowed to do that.")
    end

    test "creates a category", %{conn: conn} do
      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/categories")
      |> click_link("New Category")
      |> fill_in("Title", with: "Erlang")
      |> click_button("Create Category")
      |> assert_has("#flash-info", text: "Category created successfully.")
      |> assert_has("h1", text: "Erlang")
    end

    test "shows errors for an invalid category", %{conn: conn} do
      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/categories/new")
      |> fill_in("Title", with: "")
      |> click_button("Create Category")
      |> assert_has("p", text: "can't be blank")
      |> assert_path(~p"/categories/new")
    end
  end

  describe "edit" do
    test "renames a category", %{conn: conn} do
      category = category_fixture("Elixir")

      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/categories/#{category}")
      |> click_link("Edit")
      |> fill_in("Title", with: "Elixir & OTP")
      |> click_button("Save Category")
      |> assert_has("#flash-info", text: "Category updated successfully.")
      |> assert_has("h1", text: "Elixir & OTP")

      assert Forums.get_category!(category.id).title == "Elixir & OTP"
    end
  end

  describe "show" do
    test "shows the post count, highlighted until the thread has been read", %{conn: conn} do
      category = category_fixture("Elixir")
      user = user_fixture()
      thread = thread_fixture(category, user)
      {:ok, _} = Forums.create_post(thread, user, %{body: "Yup"})
      conn = log_in_as(conn, user)

      conn
      |> visit(~p"/categories/#{category}")
      |> assert_has("#thread-#{thread.id} .thread-title", text: "OTP is cool")
      |> assert_has("#thread-#{thread.id} .posts-count.badge-primary", text: "2")
      |> click_link("OTP is cool")
      |> assert_has("h1", text: "OTP is cool")

      conn
      |> visit(~p"/categories/#{category}")
      |> assert_has("#thread-#{thread.id} .posts-count.badge-ghost", text: "2")
    end

    test "shows new threads without a reload", %{conn: conn} do
      category = category_fixture("Elixir")
      session = visit(conn, ~p"/categories/#{category}")

      thread = thread_fixture(category, user_fixture(), %{title: "Live!"})

      assert_has(session, "#thread-#{thread.id}", text: "Live!")
    end

    test "lets an admin delete the category", %{conn: conn} do
      category = category_fixture("Doomed")

      conn
      |> log_in_as(admin_fixture())
      |> visit(~p"/categories/#{category}")
      |> click_button("Delete")
      |> assert_path(~p"/categories")
      |> assert_has("#flash-info", text: "Category deleted successfully.")

      assert_raise Ecto.NoResultsError, fn -> Forums.get_category!(category.id) end
    end

    test "hides edit and delete from visitors and members", %{conn: conn} do
      category = category_fixture("Elixir")

      conn
      |> visit(~p"/categories/#{category}")
      |> refute_has("button", text: "Delete")
      |> refute_has("a", text: "Edit")

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/categories/#{category}")
      |> refute_has("button", text: "Delete")
      |> refute_has("a", text: "Edit")
    end

    test "refuses a forged delete event from a member", %{conn: conn} do
      category = category_fixture("Elixir")

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/categories/#{category}")
      |> unwrap(&Phoenix.LiveViewTest.render_click(&1, "delete", %{}))

      assert Forums.get_category!(category.id)
    end

    test "members can't open the edit page", %{conn: conn} do
      category = category_fixture("Elixir")

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/categories/#{category}/edit")
      |> assert_path(~p"/categories")
      |> assert_has("#flash-error", text: "You are not allowed to do that.")
    end
  end
end
