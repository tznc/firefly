defmodule FirestormWeb.WikiTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias FirestormWeb.{AccountExport, Forums, Groups, SiteSettings, TopicTools}
  alias FirestormWeb.Forums.{Post, StaffAction}

  setup do
    admin = admin_fixture()
    author = user_fixture()
    member = user_fixture()
    category = category_fixture("Docs")
    thread = thread_fixture(category, author, %{title: "Guide", body: "op"})
    {:ok, post} = Forums.create_post(thread, author, %{body: "How to install"})

    %{
      admin: admin,
      author: author,
      member: member,
      category: category,
      thread: thread,
      post: post
    }
  end

  defp can_edit?(user, post, thread),
    do:
      Bodyguard.permit?(Forums, :edit_post, user, %{
        post: Repo.reload!(post),
        thread: Repo.reload!(thread)
      })

  defp log_entries(action), do: Repo.all(from(a in StaffAction, where: a.action == ^action))

  test "staff toggle wikis, logged", %{admin: admin, member: member, post: post} do
    refute Bodyguard.permit?(Forums, :toggle_wiki, member, post)
    assert Bodyguard.permit?(Forums, :toggle_wiki, admin, post)

    {:ok, wiki} = Forums.set_wiki(post, true, admin)
    assert Post.wiki?(wiki)

    assert [%{target_id: id, details: %{"excerpt" => "How to install"}}] =
             log_entries("post.wiki")

    assert id == post.id
    # Already a wiki: nothing to log.
    {:ok, _} = Forums.set_wiki(wiki, true, admin)
    assert [_] = log_entries("post.wiki")

    {:ok, normal} = Forums.set_wiki(wiki, false, admin)
    refute Post.wiki?(normal)
    assert [_] = log_entries("post.unwiki")
  end

  test "members edit wikis, with each editor in the history", %{
    admin: admin,
    author: author,
    member: member,
    post: post,
    thread: thread
  } do
    refute can_edit?(member, post, thread)
    {:ok, post} = Forums.set_wiki(post, true, admin)
    assert can_edit?(member, post, thread)
    # Editing isn't deleting.
    refute Bodyguard.permit?(Forums, :delete_post, member, %{post: post, thread: thread})

    {:ok, post} = Forums.update_post(post, member, %{body: "How to install, step by step"})
    {:ok, _post} = Forums.update_post(post, author, %{body: "How to install, steps 1-3"})

    assert [%{editor: %{id: second}}, %{editor: %{id: first}}] =
             Forums.post_edits(Repo.reload!(post))

    assert {first, second} == {member.id, author.id}
    # A member's wiki edit isn't staff action.
    assert log_entries("post.edit") == []
  end

  test "no edit window for wiki edits", %{
    admin: admin,
    member: member,
    post: post,
    thread: thread
  } do
    {:ok, _} = SiteSettings.update(%{"edit_grace_minutes" => "5"}, admin)
    old = NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)
    Repo.update_all(where(Post, id: ^post.id), set: [inserted_at: old])
    {:ok, _} = Forums.set_wiki(Repo.reload!(post), true, admin)
    assert can_edit?(member, post, thread)
  end

  test "not when closed, deleted, hidden or unreadable", %{
    admin: admin,
    author: author,
    member: member,
    category: category,
    post: post,
    thread: thread
  } do
    {:ok, post} = Forums.set_wiki(post, true, admin)

    {:ok, _} = Forums.close_thread(thread, true, admin)
    refute can_edit?(member, post, thread)
    {:ok, _} = Forums.close_thread(Repo.reload!(thread), false, admin)
    assert can_edit?(member, post, thread)

    Repo.update_all(where(Post, id: ^post.id), set: [hidden_at: DateTime.utc_now(:second)])
    refute can_edit?(member, post, thread)
    Repo.update_all(where(Post, id: ^post.id), set: [hidden_at: nil])

    {:ok, team} = Groups.create_group(%{name: "team"}, admin)
    {:ok, _} = Forums.update_category(category, %{role_ids: [team.id]}, admin)
    refute can_edit?(member, post, thread)
    {:ok, _} = Forums.update_category(Repo.reload!(category), %{"role_ids" => [""]}, admin)
    assert can_edit?(member, post, thread)

    {:ok, _} = Forums.delete_post(post, author)
    refute can_edit?(member, post, thread)
    assert {:error, :deleted} = Forums.update_post(post, member, %{body: "too late"})
  end

  test "a wiki stays a wiki through a split and a merge", %{
    admin: admin,
    member: member,
    category: category,
    post: post,
    thread: thread
  } do
    {:ok, post} = Forums.set_wiki(post, true, admin)

    {:ok, split} =
      TopicTools.split(
        thread,
        [post.id],
        {:new, %{"title" => "Wiki thread", "category_id" => category.id}},
        admin
      )

    assert Post.wiki?(Repo.reload!(post))
    assert can_edit?(member, post, split)

    target = thread_fixture(category, admin, %{title: "Target", body: "t"})
    {:ok, target} = TopicTools.merge(split, target, admin)
    assert can_edit?(member, post, target)
    # The merged stub takes no edits.
    refute Bodyguard.permit?(Forums, :edit_post, member, %{
             post: post,
             thread: Repo.reload!(split)
           })
  end

  test "wiki edits are in the editor's export, without the text", %{
    admin: admin,
    member: member,
    post: post
  } do
    {:ok, post} = Forums.set_wiki(post, true, admin)
    {:ok, _} = Forums.update_post(post, member, %{body: "Edited by a member"})

    assert [%{post_id: post_id, edited_at: _}] = AccountExport.build(member).wiki_edits
    assert post_id == post.id

    assert [%{wiki: true}] =
             AccountExport.build(Repo.preload(post, :user).user).posts |> Enum.filter(& &1.wiki)
  end
end
