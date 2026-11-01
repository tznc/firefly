defmodule FirestormWeb.Web.CategoryManagementTest do
  use FirestormWeb.Web.ConnCase

  import FirestormWeb.DataCase, only: [errors_on: 1]

  alias FirestormWeb.Forums

  test "categories have descriptions, colors, positions and subcategories", %{conn: conn} do
    admin = admin_fixture()
    elixir = category_fixture("Elixir")
    category_fixture("Announcements")

    conn
    |> log_in_as(admin)
    |> visit(~p"/categories/new")
    |> fill_in("Title", with: "Phoenix")
    |> fill_in("Description", with: "Web framework talk")
    |> select("Parent category", option: "Elixir")
    |> fill_in("Color", with: "#3b82f6")
    |> click_button("Create Category")
    |> assert_has("#flash-info", text: "Category created successfully.")
    |> assert_has("#category-description", text: "Web framework talk")
    |> assert_has("#parent-category", text: "Elixir")

    phoenix = Forums.list_categories() |> Enum.find(&(&1.title == "Phoenix"))
    assert phoenix.parent_id == elixir.id
    assert phoenix.color == "#3b82f6"

    # Subcategories show under their parent, and its threads include theirs
    thread = thread_fixture(phoenix, admin, %{title: "LiveView tips"})

    conn
    |> log_in_as(admin)
    |> visit(~p"/categories/#{elixir}")
    |> assert_has("#subcategories", text: "Phoenix")
    |> assert_has("#thread-#{thread.id}")

    conn
    |> visit(~p"/categories")
    |> assert_has("#category-#{elixir.id}", text: "Phoenix")
    |> refute_has("#category-#{phoenix.id}")
  end

  test "positions order the categories", %{conn: conn} do
    {:ok, _} = Forums.create_category(%{title: "Zed", position: 0})
    {:ok, _} = Forums.create_category(%{title: "Alpha", position: 5})

    assert ["Zed", "Alpha"] = Enum.map(Forums.list_category_tree(), & &1.title)
    conn |> visit(~p"/categories") |> assert_has("#categories li:first-child", text: "Zed")
  end

  test "invalid colors and nesting are rejected" do
    {:ok, parent} = Forums.create_category(%{title: "Parent"})
    {:ok, child} = Forums.create_category(%{title: "Child", parent_id: parent.id})

    assert {:error, changeset} = Forums.create_category(%{title: "Bad", color: "blue"})
    assert "must be a hex color like #3b82f6" in errors_on(changeset).color

    assert {:error, changeset} = Forums.create_category(%{title: "Deep", parent_id: child.id})
    assert "must be a top-level category" in errors_on(changeset).parent_id

    assert {:error, changeset} = Forums.update_category(parent, %{parent_id: parent.id})
    assert "can't be the category itself" in errors_on(changeset).parent_id

    {:ok, other} = Forums.create_category(%{title: "Other"})
    assert {:error, changeset} = Forums.update_category(parent, %{parent_id: other.id})

    assert errors_on(changeset).parent_id == [
             "a category with subcategories can't be a subcategory"
           ]
  end
end
