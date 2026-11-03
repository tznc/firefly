defmodule FireflyWeb.SEOTest do
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Discussion, Groups, SiteSettings}

  @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131 Safari/537.36"

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    user = user_fixture()
    category = category_fixture("Elixir")
    thread = thread_fixture(category, user, %{title: "OTP is cool", body: "Don't you think?"})
    %{user: user, admin: admin_fixture(), category: category, thread: thread}
  end

  describe "robots.txt" do
    test "is served from the settings", %{conn: conn, admin: admin} do
      conn = get(conn, ~p"/robots.txt")
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
      body = response(conn, 200)
      assert body =~ "Disallow: /staff/"
      assert body =~ "Sitemap: "

      {:ok, _} = SiteSettings.update(%{"allow_indexing" => "false"}, admin)
      assert build_conn() |> get(~p"/robots.txt") |> response(200) =~ "Disallow: /\n"
    end
  end

  describe "sitemaps" do
    test "the index links each sitemap, which lists public URLs", %{conn: conn, thread: thread} do
      index = conn |> get(~p"/sitemap.xml") |> response(200)
      assert index =~ "<sitemapindex"
      assert index =~ url(~p"/sitemap/#{"topics-1.xml"}")

      topics = build_conn() |> get(~p"/sitemap/#{"topics-1.xml"}") |> response(200)
      assert topics =~ "<urlset"
      assert topics =~ Firefly.URLs.thread_url(thread)
      assert topics =~ "<lastmod>"
    end

    test "unknown sitemaps are 404", %{conn: conn} do
      assert conn |> get(~p"/sitemap/#{"nope.xml"}") |> response(404)
    end

    test "with indexing off the index is empty", %{conn: conn, admin: admin} do
      {:ok, _} = SiteSettings.update(%{"allow_indexing" => "false"}, admin)

      index = conn |> get(~p"/sitemap.xml") |> response(200)
      refute index =~ "<sitemap>"
      assert conn |> get(~p"/sitemap/#{"topics-1.xml"}") |> response(404)
    end
  end

  describe "page metadata" do
    test "a topic has a canonical URL, OpenGraph and structured data", %{
      conn: conn,
      category: category,
      thread: thread,
      user: user
    } do
      {:ok, _reply} = Discussion.create_post(thread, user, %{body: "A reply"})

      html =
        conn
        |> put_req_header("user-agent", @browser)
        |> get(~p"/categories/#{category}/threads/#{thread}")
        |> html_response(200)

      assert html =~ ~s{<link rel="canonical" href="#{Firefly.URLs.thread_url(thread)}"}
      assert html =~ ~s{property="og:type" content="article"}
      assert html =~ ~s{property="og:title" content="OTP is cool"}
      assert html =~ ~s{name="description" content="Don&#39;t you think?"}
      assert html =~ ~s{name="twitter:card"}
      refute html =~ ~s{name="robots"}

      assert %{"@type" => "DiscussionForumPosting"} =
               discussion = json_ld(html, "DiscussionForumPosting")

      assert discussion["headline"] == "OTP is cool"
      assert [%{"@type" => "Comment", "text" => "A reply"}] = discussion["comment"]
      assert discussion["author"]["name"] == user.username

      assert %{"itemListElement" => crumbs} = json_ld(html, "BreadcrumbList")

      assert Enum.map(crumbs, & &1["name"]) == [
               SiteSettings.get("title"),
               "Elixir",
               "OTP is cool"
             ]
    end

    test "the home page describes the site and its search", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert %{"potentialAction" => action} = json_ld(html, "WebSite")
      assert action["target"]["urlTemplate"] =~ "/search?q={search_term_string}"
      assert json_ld(html, "Organization")["logo"] =~ "/images/icon-512.png"
    end

    test "private topics and personal lists say noindex", %{conn: conn, admin: admin} do
      {:ok, team} = Groups.create_role("team")
      {:ok, private} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      hidden = thread_fixture(private, admin, %{title: "Hidden", body: "Secret"})

      html =
        conn
        |> log_in_as(admin)
        |> put_req_header("user-agent", @browser)
        |> get(~p"/categories/#{private}/threads/#{hidden}")
        |> html_response(200)

      assert html =~ ~s{name="robots" content="noindex, follow"}

      assert conn |> log_in_as(admin) |> get(~p"/unread") |> html_response(200) =~
               ~s{name="robots" content="noindex}

      assert conn |> get(~p"/search") |> html_response(200) =~ ~s{name="robots" content="noindex}
    end

    test "member pages are noindex until the setting says otherwise", %{
      conn: conn,
      admin: admin,
      user: user
    } do
      assert conn |> get(~p"/users/#{user}") |> html_response(200) =~
               ~s{name="robots" content="noindex}

      {:ok, _} = SiteSettings.update(%{"index_user_pages" => "true"}, admin)

      html = build_conn() |> get(~p"/users/#{user}") |> html_response(200)
      refute html =~ ~s{name="robots"}
      assert html =~ ~s{<link rel="canonical" href="#{Firefly.URLs.user_url(user)}"}
    end

    test "with indexing off every page says noindex", %{conn: conn, admin: admin} do
      {:ok, _} = SiteSettings.update(%{"allow_indexing" => "false"}, admin)

      assert conn |> get(~p"/") |> html_response(200) =~ ~s{name="robots" content="noindex}
    end
  end

  describe "the crawler view" do
    test "serves a topic without LiveView, paginated", %{
      conn: conn,
      category: category,
      thread: thread,
      user: user
    } do
      for n <- 1..FireflyWeb.CrawlerController.per_page() do
        {:ok, _} = Discussion.create_post(thread, user, %{body: "Reply #{n}"})
      end

      conn = put_req_header(conn, "user-agent", @googlebot)
      html = conn |> get(~p"/categories/#{category}/threads/#{thread}") |> html_response(200)

      refute html =~ "data-phx-main"
      assert html =~ ~s{rel="next"}
      assert html =~ "Page 1 of 2"

      # The posts themselves, not the structured data in the head.
      posts = body(html)
      assert posts =~ "Don't you think?"
      assert posts =~ "Reply 1"
      refute posts =~ "Reply #{FireflyWeb.CrawlerController.per_page()}"

      second =
        conn
        |> get(~p"/categories/#{category}/threads/#{thread}?page=2")
        |> html_response(200)

      assert body(second) =~ "Reply #{FireflyWeb.CrawlerController.per_page()}"
      assert second =~ ~s{rel="prev"}
      assert second =~ ~s{<link rel="canonical" href="#{Firefly.URLs.thread_url(thread)}?page=2"}
    end

    test "readers with a browser still get the LiveView", %{
      conn: conn,
      category: category,
      thread: thread
    } do
      html =
        conn
        |> put_req_header("user-agent", @browser)
        |> get(~p"/categories/#{category}/threads/#{thread}")
        |> html_response(200)

      assert html =~ "data-phx-main"
    end

    test "hides what a visitor may not read", %{conn: conn, admin: admin} do
      {:ok, team} = Groups.create_role("team")
      {:ok, private} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      hidden = thread_fixture(private, admin, %{title: "Hidden", body: "Secret"})

      assert_error_sent(404, fn ->
        conn
        |> put_req_header("user-agent", @googlebot)
        |> get(~p"/categories/#{private}/threads/#{hidden}")
      end)
    end

    test "every page carries the noscript fallback", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200) =~ "<noscript>"
    end
  end

  # The page's content, without the metadata in its head.
  defp body(html), do: html |> String.split("<main", parts: 2) |> List.last()

  # The first JSON-LD block of `type` on the page.
  defp json_ld(html, type) do
    ~r{<script type="application/ld\+json">\s*(.+?)\s*</script>}s
    |> Regex.scan(html)
    |> Enum.map(fn [_, json] -> Jason.decode!(json) end)
    |> Enum.find(&(&1["@type"] == type))
  end
end
