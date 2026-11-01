defmodule FirestormWeb.Web.SolvedLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.Category

  setup do
    asker = user_fixture(%{username: "asker"})
    helper = user_fixture(%{username: "helper"})
    {:ok, qa} = Forums.create_category(%{title: "Questions", allow_accepted_answers: true})
    thread = thread_fixture(qa, asker, %{title: "Why OTP", body: "the question"})
    {:ok, answer} = Forums.create_post(thread, helper, %{body: "because supervisors"})
    %{asker: asker, helper: helper, qa: qa, thread: thread, answer: answer}
  end

  defp path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  test "the author accepts and unaccepts an answer", %{
    conn: conn,
    asker: asker,
    qa: qa,
    thread: thread,
    answer: answer
  } do
    conn
    |> log_in_as(asker)
    |> visit(path(thread))
    |> refute_has("#accepted-answer")
    |> click_button("Accept post #{answer.id} as the answer")
    |> assert_has("#flash-info", text: "Answer accepted")
    |> assert_has("#accepted-answer", text: "@helper")
    |> assert_has("#accepted-answer a[href='#post-#{answer.id}']", text: "Jump to answer")
    |> assert_has("#post-#{answer.id} .accepted-badge")
    |> assert_has("h1 .solved-badge")
    |> visit(~p"/categories/#{qa}")
    |> assert_has("#thread-#{thread.id} .solved-badge", text: "Solved")
    |> visit(path(thread))
    |> click_button("Unaccept post #{answer.id} as the answer")
    |> assert_has("#flash-info", text: "Answer unaccepted")
    |> refute_has("#accepted-answer")
  end

  test "others get no accept button", %{conn: conn, helper: helper, thread: thread} do
    conn
    |> log_in_as(helper)
    |> visit(path(thread))
    |> refute_has("button", text: "Accept answer")
  end

  test "deleting the accepted answer clears it live", %{
    conn: conn,
    asker: asker,
    helper: helper,
    thread: thread,
    answer: answer
  } do
    {:ok, _} = FirestormWeb.Solved.accept(thread, answer, asker)

    session =
      conn
      |> log_in_as(asker)
      |> visit(path(thread))
      |> assert_has("#accepted-answer")

    {:ok, _} = Forums.delete_post(answer, helper)
    refute_has(session, "#accepted-answer")
  end

  test "admins allow accepted answers per category", %{conn: conn} do
    admin = admin_fixture()
    category = category_fixture("Chat")

    conn
    |> log_in_as(admin)
    |> visit(~p"/categories/#{category}/edit")
    |> check("Allow accepted answers", exact: false)
    |> click_button("Save")

    assert Repo.get!(Category, category.id).allow_accepted_answers
  end
end
