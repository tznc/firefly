defmodule FireflyWeb.BulkModerationTest do
  use FireflyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [element: 2, render_click: 1]

  alias Firefly.{Discussion, Repo, SiteSettings}
  alias Firefly.Discussion.Thread
  alias Firefly.Moderation.Review

  setup do
    category = category_fixture()
    author = user_fixture()

    threads =
      for title <- ["Alpha", "Beta"], do: thread_fixture(category, author, %{title: title})

    %{category: category, threads: threads}
  end

  defp select(session, selector),
    do: unwrap(session, &render_click(element(&1, selector)))

  test "staff select threads on a list and close them", %{conn: conn, threads: [alpha, beta]} do
    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/")
    |> refute_has("#bulk-count")
    |> select("#thread-#{alpha.id} .bulk-select")
    |> select("#thread-#{beta.id} .bulk-select")
    |> assert_has("#bulk-count", text: "2 selected")
    |> click_button("#bulk-actions button", "Close")
    |> assert_has("#flash-info", text: "Updated 2 threads.")
    |> refute_has("#bulk-count")

    assert Thread.closed?(Repo.get!(Thread, alpha.id))
    assert Thread.closed?(Repo.get!(Thread, beta.id))
  end

  test "staff move a category's threads", %{conn: conn, category: category, threads: threads} do
    other = category_fixture("Erlang")

    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/categories/#{category}")
    |> click_button("Select all")
    |> within(
      "#bulk-move",
      &(&1 |> select("Move to category", option: "Erlang") |> click_button("Move"))
    )
    |> assert_has("#flash-info", text: "Updated 2 threads.")

    assert Enum.all?(threads, &(Repo.get!(Thread, &1.id).category_id == other.id))
  end

  test "members can only mark threads read", %{conn: conn, threads: [alpha | _]} do
    member = user_fixture()

    conn
    |> log_in_as(member)
    |> visit(~p"/")
    |> select("#thread-#{alpha.id} .bulk-select")
    |> refute_has("#bulk-actions button", text: "Close")
    |> click_button("#bulk-actions button", "Mark read")
    |> assert_has("#flash-info", text: "Updated 1 thread.")

    assert Discussion.thread_read(member, alpha)
  end

  test "visitors get no checkboxes", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> refute_has(".bulk-select")
    |> refute_has("#bulk-actions")
  end

  test "staff approve queued posts together", %{conn: conn, threads: [alpha | _]} do
    admin = admin_fixture()
    SiteSettings.update(%{"approve_new_user_posts" => "5"}, admin)
    newbie = user_fixture()

    [one, two] =
      for n <- 1..2 do
        {:ok, post} = Discussion.create_post(alpha, newbie, %{body: "Reply #{n}"})
        post
      end

    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/review")
    |> select("#queued-#{one.id} input[type=checkbox]")
    |> select("#queued-#{two.id} input[type=checkbox]")
    |> assert_has("#selected-count", text: "2 selected")
    |> click_button("Approve selected")
    |> assert_has("#flash-info", text: "Approved 2 of 2 selected posts.")

    assert Review.queued_posts() == []
  end
end
