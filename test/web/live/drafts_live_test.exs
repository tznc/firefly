defmodule FirestormWeb.Web.DraftsLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Drafts, Forums}

  setup do
    user = user_fixture()
    category = category_fixture()
    thread = thread_fixture(category, user, %{title: "Drafty", body: "opening"})
    %{user: user, category: category, thread: thread}
  end

  defp reply_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new"

  test "a reply is kept as a draft until it's posted", %{conn: conn, user: user, thread: thread} do
    conn
    |> log_in_as(user)
    |> visit(reply_path(thread))
    |> refute_has("#draft-status")
    |> fill_in("Body", with: "half a thought")
    |> assert_has("#draft-status", text: "Draft saved")

    assert Drafts.get(user, {:reply, thread}).body == "half a thought"

    conn
    |> log_in_as(user)
    |> visit(reply_path(thread))
    |> assert_has("textarea", text: "half a thought")
    |> fill_in("Body", with: "a whole thought")
    |> click_button("Reply")
    |> assert_has("#flash-info", text: "Post created")

    refute Drafts.get(user, {:reply, thread})
  end

  test "discarding a draft clears the composer", %{conn: conn, user: user, thread: thread} do
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "never mind"})

    conn
    |> log_in_as(user)
    |> visit(reply_path(thread))
    |> assert_has("textarea", text: "never mind")
    |> click_button("Discard draft")
    |> refute_has("textarea", text: "never mind")
    |> refute_has("#draft-status")

    refute Drafts.get(user, {:reply, thread})
  end

  test "a quote opened over a draft is added to it", %{conn: conn, user: user, thread: thread} do
    {:ok, _} = Drafts.save(user, {:reply, thread}, %{body: "my draft"})
    [op] = Forums.get_thread!(thread.id) |> FirestormWeb.Repo.preload(:posts) |> Map.get(:posts)

    conn
    |> log_in_as(user)
    |> visit(reply_path(thread) <> "?quote=#{op.id}")
    |> assert_has("textarea", text: "my draft")
    |> assert_has("textarea", text: "opening")
  end

  test "a new thread draft per category keeps title, tags and body", %{
    conn: conn,
    user: user,
    category: category
  } do
    other = category_fixture("Other")

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{category}/threads/new")
    |> fill_in("Title", with: "Big idea")
    |> fill_in("Tags", with: "otp")
    |> fill_in("Body", with: "Details")
    |> assert_has("#draft-status", text: "Draft saved")

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{other}/threads/new")
    |> refute_has("#draft-status")

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{category}/threads/new")
    |> assert_has("input[name='thread[title]'][value='Big idea']")
    |> assert_has("input[name='thread[tags]'][value='otp']")
    |> assert_has("textarea", text: "Details")
    |> click_button("Create Thread")
    |> assert_has("#flash-info", text: "Thread created")

    refute Drafts.get(user, {:new_thread, category})
  end

  test "an unsaved edit is kept; going back to the post's text drops it", %{
    conn: conn,
    user: user,
    thread: thread
  } do
    {:ok, reply} = Forums.create_post(thread, user, %{body: "original"})
    path = ~p"/categories/#{thread.category_id}/threads/#{thread}/posts/#{reply}/edit"

    conn
    |> log_in_as(user)
    |> visit(path)
    |> fill_in("Body", with: "revised")
    |> assert_has("#draft-status")

    conn
    |> log_in_as(user)
    |> visit(path)
    |> assert_has("textarea", text: "revised")
    |> fill_in("Body", with: "original")
    |> refute_has("#draft-status")

    refute Drafts.get(user, {:edit, reply})

    {:ok, _} = Drafts.save(user, {:edit, reply}, %{body: "revised again"})

    conn
    |> log_in_as(user)
    |> visit(path)
    |> click_button("Save edit")
    |> assert_has("#flash-info", text: "Post updated")

    refute Drafts.get(user, {:edit, reply})
    assert Forums.get_post!(reply.id).body == "revised again"
  end

  test "the drafts page lists, resumes and deletes", %{
    conn: conn,
    user: user,
    category: category,
    thread: thread
  } do
    {:ok, reply_draft} = Drafts.save(user, {:reply, thread}, %{body: "a reply"})
    {:ok, _} = Drafts.save(user, {:new_thread, category}, %{title: "A thread"})

    session =
      conn
      |> log_in_as(user)
      |> visit(~p"/")
      |> click_link("Drafts")
      |> assert_path(~p"/drafts")
      |> assert_has("#draft-#{reply_draft.id}", text: "Reply to Drafty")
      |> assert_has("#drafts li", text: "New thread in #{category.title}: A thread")

    session
    |> click_button("#draft-#{reply_draft.id} button", "Delete")
    |> assert_has("#flash-info", text: "Draft deleted.")
    |> refute_has("#draft-#{reply_draft.id}")
    |> click_link("Resume")
    |> assert_path(~p"/categories/#{category}/threads/new")

    build_conn()
    |> log_in_as(user_fixture())
    |> visit(~p"/drafts")
    |> assert_has("#no-drafts")
  end
end
