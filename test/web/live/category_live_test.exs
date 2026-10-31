defmodule FirestormWeb.Web.CategoryLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  describe "index" do
    test "lists categories", %{conn: conn} do
      category_fixture("Elixir")
      category_fixture("Elm")

      {:ok, view, html} = live(conn, ~p"/categories")

      assert html =~ "Categories"
      assert has_element?(view, "#categories li", "Elixir")
      assert has_element?(view, "#categories li", "Elm")
    end

    test "shows categories created elsewhere without a reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/categories")
      refute has_element?(view, "#categories", "Erlang")

      category_fixture("Erlang")

      assert render(view) =~ "Erlang"
    end
  end

  describe "new" do
    test "redirects visitors to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/categories", flash: flash}}} =
               live(conn, ~p"/categories/new")

      assert flash["error"] == "You must be logged in to access this page."
    end

    test "creates a category", %{conn: conn} do
      conn = log_in_as(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/categories/new")

      {:ok, _show, html} =
        view
        |> form("#category-form", category: %{title: "Erlang"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Category created successfully."
      assert html =~ "Erlang"
    end

    test "shows errors for an invalid category", %{conn: conn} do
      conn = log_in_as(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/categories/new")

      assert view |> form("#category-form", category: %{title: ""}) |> render_submit() =~
               "can&#39;t be blank"
    end
  end

  describe "edit" do
    test "renames a category", %{conn: conn} do
      category = category_fixture("Elixir")
      conn = log_in_as(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}/edit")

      {:ok, _show, html} =
        view
        |> form("#category-form", category: %{title: "Elixir & OTP"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "Category updated successfully."
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

      {:ok, view, _html} = live(conn, ~p"/categories/#{category}")
      assert has_element?(view, "#thread-#{thread.id} .thread-title", "OTP is cool")
      assert has_element?(view, "#thread-#{thread.id} .posts-count.badge-primary", "2")

      {:ok, _thread_view, _html} = live(conn, ~p"/categories/#{category}/threads/#{thread}")

      {:ok, view, _html} = live(conn, ~p"/categories/#{category}")
      assert has_element?(view, "#thread-#{thread.id} .posts-count.badge-ghost", "2")
    end

    test "shows new threads without a reload", %{conn: conn} do
      category = category_fixture("Elixir")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}")

      thread = thread_fixture(category, user_fixture(), %{title: "Live!"})

      assert render(view) =~ "Live!"
      assert has_element?(view, "#thread-#{thread.id}")
    end

    test "lets a logged-in user delete the category", %{conn: conn} do
      category = category_fixture("Doomed")
      conn = log_in_as(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}")

      {:ok, _index, html} =
        view |> element("button", "Delete") |> render_click() |> follow_redirect(conn)

      assert html =~ "Category deleted successfully."
      assert_raise Ecto.NoResultsError, fn -> Forums.get_category!(category.id) end
    end

    test "hides edit and delete from visitors", %{conn: conn} do
      category = category_fixture("Elixir")
      {:ok, view, _html} = live(conn, ~p"/categories/#{category}")

      refute has_element?(view, "button", "Delete")
      refute has_element?(view, "a", "Edit")
    end
  end
end
