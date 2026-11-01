defmodule FirestormWeb.Web.SearchLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Forums

  setup do
    alice = user_fixture(%{username: "alice"})
    category = category_fixture()

    thread =
      thread_fixture(category, alice, %{title: "Supervisors", body: "Let it crash, they say."})

    %{thread: thread, category: category}
  end

  test "searching from the top bar links results to the post", %{conn: conn, thread: thread} do
    [post] = Forums.get_thread!(thread.id) |> FirestormWeb.Repo.preload(:posts) |> Map.get(:posts)

    conn
    |> visit(~p"/")
    |> within("form[role=search]", &fill_in(&1, "Search the forum", with: "crashing"))
    |> submit()
    |> assert_path(~p"/search", query_params: %{q: "crashing"})
    |> assert_has("#search-results", text: "1 result")
    |> assert_has("#result-#{post.id} .result-snippet mark", text: "crash")
    |> assert_has(
      "#result-#{post.id} a.result-title[href='/categories/#{thread.category_id}/threads/#{thread.id}#post-#{post.id}']"
    )
  end

  test "filter controls go into the URL", %{conn: conn, category: category} do
    conn
    |> visit(~p"/search")
    |> refute_has("#search-results")
    |> fill_in("Search terms", with: "crash")
    |> select("Category", option: category.title)
    |> fill_in("Posted by", with: "nobody")
    |> click_button("Search")
    |> assert_path(~p"/search",
      query_params: %{q: "crash", category: category.slug, user: "nobody", order: "relevance"}
    )
    |> assert_has("#search-results", text: "0 results")
    |> fill_in("Posted by", with: "alice")
    |> check("Titles only")
    |> fill_in("Search terms", with: "supervisors")
    |> click_button("Search")
    |> assert_has("#search-results .result-title", text: "Supervisors")
  end

  test "GET /api/v1/search returns results as JSON", %{conn: conn, thread: thread} do
    response = conn |> get(~p"/api/v1/search?q=crash") |> json_response(200)

    assert %{"total_entries" => 1, "results" => [result]} = response
    assert result["thread_id"] == thread.id
    assert result["username"] == "alice"
    assert result["headline_html"] =~ "<mark>crash</mark>"
    assert result["url"] =~ "/threads/#{thread.id}#post-#{result["post_id"]}"
  end
end
