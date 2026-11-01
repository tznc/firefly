defmodule FirestormWeb.TagGroupsTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase, only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1]

  alias FirestormWeb.{Forums, Search, Tags}
  alias FirestormWeb.Forums.{StaffAction, Subscriptions, Tag, TagGroup}

  setup do
    %{admin: admin_fixture(), member: user_fixture(), category: category_fixture("Elixir")}
  end

  defp create(category, user, tags, title \\ "T") do
    Forums.create_thread(category, user, %{title: title, body: "B", tags: tags})
  end

  defp tag_names(thread),
    do: thread |> Repo.preload(:tags, force: true) |> Map.get(:tags) |> Enum.map(& &1.name)

  defp log(action), do: Repo.all(from(a in StaffAction, where: a.action == ^action))

  defp tag!(name), do: Repo.get_by!(Tag, name: name)

  describe "groups" do
    test "create, update and delete, logged", %{admin: admin} do
      {:ok, group} =
        Tags.create_group(
          %{"name" => "Status", "tags" => "solved, wontfix", "one_per_thread" => "true"},
          admin
        )

      assert %TagGroup{name: "Status", one_per_thread: true, staff_only: false} = group
      assert Enum.map(group.tags, & &1.name) == ["solved", "wontfix"]
      assert [%{details: %{"name" => "Status"}}] = log("tag_group.create")

      {:ok, other} = Tags.create_group(%{"name" => "Other", "tags" => "misc"}, admin)

      # Tags move between groups and leave when dropped.
      {:ok, group} =
        Tags.update_group(group, %{"tags" => "solved misc", "staff_only" => "true"}, admin)

      assert Enum.map(group.tags, & &1.name) == ["misc", "solved"]
      assert group.staff_only
      assert tag!("wontfix").group_id == nil
      assert Tags.get_group!(other.id).tags == []

      assert [
               %{
                 details: %{"tags" => %{"before" => "solved, wontfix", "after" => "misc, solved"}}
               }
             ] =
               log("tag_group.update")

      # Nothing changed: not logged.
      {:ok, _} = Tags.update_group(group, %{"tags" => "misc, solved"}, admin)
      assert length(log("tag_group.update")) == 1

      {:ok, _} = Tags.delete_group(group, admin)
      assert tag!("solved").group_id == nil
      assert [_] = log("tag_group.delete")
    end

    test "names are unique and tags valid", %{admin: admin} do
      {:ok, _} = Tags.create_group(%{"name" => "Status"}, admin)
      assert {:error, changeset} = Tags.create_group(%{"name" => "Status"}, admin)
      assert "has already been taken" in errors_on(changeset).name
      assert {:error, changeset} = Tags.create_group(%{"name" => "X", "tags" => "Bad_Tag"}, admin)
      assert errors_on(changeset).tags != []
    end

    test "staff-only tags: only admins add them, members' edits keep them", %{
      admin: admin,
      member: member,
      category: category
    } do
      {:ok, _} =
        Tags.create_group(
          %{"name" => "Official", "tags" => "announcement", "staff_only" => "true"},
          admin
        )

      assert {:error, changeset} = create(category, member, "announcement, otp")
      assert "announcement: only staff can use this tag" in errors_on(changeset).tags

      {:ok, thread} = create(category, admin, "announcement")
      {:ok, thread} = Forums.update_thread(thread, %{"tags" => "otp"}, member)
      assert tag_names(thread) == ["announcement", "otp"]

      # Admins can remove it.
      {:ok, thread} = Forums.update_thread(thread, %{"tags" => "otp"}, admin)
      assert tag_names(thread) == ["otp"]
    end

    test "one tag per thread from a one-per-thread group", %{
      admin: admin,
      member: member,
      category: category
    } do
      {:ok, _} =
        Tags.create_group(
          %{"name" => "Status", "tags" => "solved open", "one_per_thread" => "true"},
          admin
        )

      assert {:error, changeset} = create(category, member, "solved, open")
      assert "solved, open: pick one of the Status tags" in errors_on(changeset).tags
      assert {:ok, thread} = create(category, member, "solved, otp")
      assert {:error, _} = Forums.update_thread(thread, %{"tags" => "solved open"}, admin)
    end

    test "the picker offers tags by group, staff-only ones to staff", %{
      admin: admin,
      member: member,
      category: category
    } do
      {:ok, _} =
        Tags.create_group(
          %{"name" => "Official", "tags" => "announcement", "staff_only" => "true"},
          admin
        )

      {:ok, _} = Tags.create_group(%{"name" => "Status", "tags" => "solved"}, admin)
      {:ok, _} = create(category, member, "otp")

      picked = fn user ->
        Enum.map(Tags.picker(user), fn {g, tags} -> {g && g.name, Enum.map(tags, & &1.name)} end)
      end

      assert picked.(member) == [{"Status", ["solved"]}, {nil, ["otp"]}]

      assert picked.(admin) == [
               {"Official", ["announcement"]},
               {"Status", ["solved"]},
               {nil, ["otp"]}
             ]
    end
  end

  describe "synonyms" do
    test "making a synonym re-tags threads and moves watchers", %{
      admin: admin,
      member: member,
      category: category
    } do
      {:ok, a} = create(category, member, "js", "A")
      {:ok, b} = create(category, member, "js javascript", "B")
      {:ok, _} = Subscriptions.set_tag_level(member, tag!("js"), "watching")

      {:ok, synonym} = Tags.make_synonym("js", "javascript", admin)
      assert synonym.synonym_of_id == tag!("javascript").id

      assert tag_names(a) == ["javascript"]
      assert tag_names(b) == ["javascript"]
      assert Subscriptions.tag_level(member, tag!("javascript")) == "watching"
      assert Subscriptions.tag_level(member, tag!("js")) == nil

      assert [%{details: %{"name" => "js", "synonym_of" => "javascript", "threads" => 2}}] =
               log("tag.synonym")

      # Applying the synonym stores the canonical tag.
      {:ok, c} = create(category, member, "js, JS, otp", "C")
      assert tag_names(c) == ["javascript", "otp"]
      assert Tags.canonical_name("JS") == "javascript"
    end

    test "search treats them as one", %{admin: admin, member: member, category: category} do
      {:ok, _} = create(category, member, "javascript", "Closures")
      {:ok, _} = Tags.make_synonym("js", "javascript", admin)

      results = Search.run(Search.parse("tag:js"), member).entries
      assert [%{thread: %{title: "Closures"}}] = results
    end

    test "no chains, no self-synonyms", %{admin: admin} do
      {:ok, _} = Tags.make_synonym("js", "javascript", admin)
      assert {:error, :canonical_is_synonym} = Tags.make_synonym("ecmascript", "js", admin)
      assert {:error, :same_tag} = Tags.make_synonym("js", "js", admin)
      assert {:error, :invalid} = Tags.make_synonym("", "x", admin)

      # A synonym's synonyms follow it to the new canonical tag.
      {:ok, _} = Tags.make_synonym("javascript", "ecmascript", admin)
      assert tag!("js").synonym_of_id == tag!("ecmascript").id

      # Synonyms can't join groups.
      assert {:error, _} = Tags.create_group(%{"name" => "Langs", "tags" => "js"}, admin)
    end

    test "removing a synonym", %{admin: admin} do
      {:ok, synonym} = Tags.make_synonym("js", "javascript", admin)
      {:ok, tag} = Tags.remove_synonym(synonym, admin)
      assert tag.synonym_of_id == nil
      assert [%{details: %{"synonym_of" => "javascript"}}] = log("tag.unsynonym")
      assert Tags.list_synonyms() == []
    end
  end
end
