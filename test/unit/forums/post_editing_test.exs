defmodule FirestormWeb.Forums.PostEditingTest do
  use FirestormWeb.DataCase

  import FirestormWeb.Web.ConnCase, only: [user_fixture: 0, admin_fixture: 0, category_fixture: 0]

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Diff, Policy, PostRevision}

  setup do
    author = user_fixture()
    thread = FirestormWeb.Web.ConnCase.thread_fixture(category_fixture(), author)
    {:ok, post} = Forums.create_post(thread, author, %{body: "first draft"})
    %{author: author, thread: thread, post: post}
  end

  test "an edit keeps the replaced body as a revision", %{author: author, post: post} do
    Forums.subscribe("forums:thread:#{post.thread_id}")

    assert {:ok, edited} = Forums.update_post(post, author, %{body: "second draft"})
    assert edited.body == "second draft"
    assert edited.edited_at
    assert_receive {:post_updated, %{id: id}} when id == post.id

    assert [%PostRevision{body: "first draft", user_id: user_id}] = Repo.all(PostRevision)
    assert user_id == author.id
  end

  test "saving the same body records nothing", %{author: author, post: post} do
    assert {:ok, same} = Forums.update_post(post, author, %{body: "first draft"})
    assert same.edited_at == nil
    assert Repo.all(PostRevision) == []
  end

  test "invalid edits are rejected", %{author: author, post: post} do
    assert {:error, changeset} = Forums.update_post(post, author, %{body: ""})
    assert "can't be blank" in errors_on(changeset).body
    assert Repo.all(PostRevision) == []
  end

  test "new accounts' link limit applies to edits", %{author: author, post: post} do
    links = "https://a.example https://b.example https://c.example"
    assert {:error, changeset} = Forums.update_post(post, author, %{body: links})
    assert "new accounts can include at most 2 links per post" in errors_on(changeset).body

    assert {:ok, _} = Forums.update_post(post, admin_fixture(), %{body: links})
  end

  test "post_edits/1 lists edits newest first with their diffs", %{author: author, post: post} do
    admin = admin_fixture()
    {:ok, post} = Forums.update_post(post, author, %{body: "second draft"})
    {:ok, post} = Forums.update_post(post, admin, %{body: "second draft, polished"})

    assert [latest, first] = Forums.post_edits(post)
    assert latest.editor.id == admin.id
    assert latest.diff == [eq: "second ", del: "draft", ins: "draft, polished"]
    assert first.editor.id == author.id
    assert first.diff == [del: "first", ins: "second", eq: " draft"]
  end

  test "word diffs keep whitespace and line breaks" do
    assert Diff.words("a\nb c", "a\nb d") == [eq: "a\nb ", del: "c", ins: "d"]
    assert Diff.words("", "new") == [ins: "new"]
  end

  describe ":edit_post policy" do
    test "authors edit their posts while the thread is open, admins always", ctx do
      %{author: author, thread: thread, post: post} = ctx
      params = %{post: post, thread: thread}

      assert :ok = Policy.authorize(:edit_post, author, params)
      assert :ok = Policy.authorize(:edit_post, admin_fixture(), params)
      assert {:error, :unauthorized} = Policy.authorize(:edit_post, user_fixture(), params)
      assert {:error, :unauthenticated} = Policy.authorize(:edit_post, nil, params)

      {:ok, closed} = Forums.close_thread(thread, true, admin_fixture())
      closed_params = %{post: post, thread: closed}
      assert {:error, :unauthorized} = Policy.authorize(:edit_post, author, closed_params)
      assert :ok = Policy.authorize(:edit_post, admin_fixture(), closed_params)
    end
  end
end
