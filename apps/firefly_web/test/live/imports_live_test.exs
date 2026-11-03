defmodule FireflyWeb.ImportsLiveTest do
  use FireflyWeb.ConnCase, async: true

  alias Firefly.Import

  test "admins see the import runs, their counts and log", %{conn: conn} do
    {:ok, old} = Import.start_run("phpbb", [])
    Import.finish_run(old, "failed", %{}, ["Couldn't open the source: refused"], "refused")
    {:ok, run} = Import.start_run("discourse", [], true)

    Import.update_run(run, %{"posts" => %{"imported" => 12, "failed" => 1}}, [
      "posts: 12 imported"
    ])

    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/staff/import")
    |> assert_has("#import-runs li", count: 2)
    |> assert_has("#import-run-#{run.id}", text: "discourse (dry run)")
    |> assert_has("#import-run-#{run.id} .badge", text: "running")
    |> assert_has("#import-counts td", text: "12")
    |> assert_has("#import-log", text: "posts: 12 imported")
    |> click_link("#import-run-#{old.id} a", "phpbb")
    |> assert_has("#import-run h2", text: "phpbb: failed")
    |> assert_has("#import-log", text: "refused")
  end

  test "an empty list, and members can't see it", %{conn: conn} do
    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/staff/import")
    |> assert_has("#imports-empty")

    build_conn()
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/import")
    |> assert_path(~p"/")
  end

  describe "permalinks" do
    test "redirect old URLs to what they became", %{conn: conn} do
      user = user_fixture()
      category = category_fixture()
      thread = thread_fixture(category, user)
      [post] = Firefly.Repo.preload(thread, :posts).posts
      {:ok, _} = Import.put_permalink("phpbb", "viewtopic.php?t=12", {:thread_id, thread.id})
      {:ok, _} = Import.put_permalink("phpbb", "viewtopic.php?p=99", {:post_id, post.id})
      {:ok, _} = Import.put_permalink("phpbb", "viewforum.php?f=3", {:category_id, category.id})
      {:ok, _} = Import.put_permalink("discourse", "u/old-name", {:user_id, user.id})
      {:ok, tag} = Firefly.Import.Writer.tag("elixir")
      {:ok, _} = Import.put_permalink("discourse", "tag/elixir", {:tag_id, tag.id})

      {:ok, _} =
        Import.put_permalink("discourse", "faq", {:external_url, "https://example.org/faq"})

      thread_path = ~p"/categories/#{category}/threads/#{thread}"
      assert redirected_to(get(conn, "/viewtopic.php?f=1&t=12"), 301) == thread_path

      assert redirected_to(get(conn, "/viewtopic.php?p=99"), 301) ==
               thread_path <> "#post-#{post.id}"

      assert redirected_to(get(conn, "/viewforum.php?f=3"), 301) == ~p"/categories/#{category}"
      assert redirected_to(get(conn, "/u/old-name/summary"), 301) == ~p"/users/#{user}"
      assert redirected_to(get(conn, "/tag/elixir"), 301) == ~p"/tags/elixir"
      assert redirected_to(get(conn, "/faq"), 301) == "https://example.org/faq"
    end

    test "anything else is still not found", %{conn: conn} do
      assert get(conn, "/viewtopic.php?t=404") |> response(404) =~ "Not Found"
      assert get(conn, "/no/such/page") |> response(404) =~ "Not Found"
    end
  end
end
