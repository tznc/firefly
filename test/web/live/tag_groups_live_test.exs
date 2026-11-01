defmodule FirestormWeb.Web.TagGroupsLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Repo, Tags}
  alias FirestormWeb.Forums.{Tag, TagGroup}

  setup do
    %{admin: admin_fixture(), member: user_fixture(), category: category_fixture()}
  end

  test "members can't manage tags", %{conn: conn, member: member} do
    conn
    |> log_in_as(member)
    |> visit(~p"/staff/tags")
    |> assert_path("/")
    |> assert_has("#flash-error")
  end

  test "admins create and edit groups", %{conn: conn, admin: admin} do
    session =
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/tags")
      |> within("#new-tag-group-form", fn session ->
        session
        |> fill_in("Name", with: "Status")
        |> fill_in("Tags", with: "solved, open")
        |> check("At most one of these tags per thread")
        |> click_button("Create group")
      end)
      |> assert_has("#flash-info", text: "Tag group Status created.")

    group = Repo.get_by!(TagGroup, name: "Status")
    assert group.one_per_thread

    session
    |> within("#tag-group-#{group.id}", fn session ->
      session
      |> fill_in("Tags", with: "solved")
      |> check("Only staff can use these tags")
      |> click_button("Save")
    end)
    |> assert_has("#flash-info", text: "Tag group Status saved.")
    |> assert_has("#tag-group-#{group.id} .badge", text: "staff only")

    assert Repo.get_by!(Tag, name: "open").group_id == nil
  end

  test "admins make synonyms; the synonym's page redirects", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/tags")
    |> fill_in("Make the tag", with: "js")
    |> fill_in("a synonym of", with: "javascript")
    |> click_button("#synonym-form button", "Save")
    |> assert_has("#flash-info", text: "js is now a synonym of javascript.")
    |> assert_has("#synonyms li", text: "js → javascript")

    build_conn() |> visit(~p"/tags/js") |> assert_path(~p"/tags/javascript")
  end

  test "the thread form's picker shows tags by group and fills the field", %{
    conn: conn,
    admin: admin,
    member: member,
    category: category
  } do
    {:ok, _} = Tags.create_group(%{"name" => "Status", "tags" => "solved"}, admin)

    {:ok, _} =
      Tags.create_group(%{"name" => "Official", "tags" => "news", "staff_only" => "true"}, admin)

    conn
    |> log_in_as(member)
    |> visit(~p"/categories/#{category}/threads/new")
    |> assert_has("#tag-picker", text: "Status")
    |> refute_has("#tag-picker", text: "Official")
    |> click_button("#tag-picker button", "solved")
    |> assert_has("input[name='thread[tags]'][value='solved']")
  end
end
