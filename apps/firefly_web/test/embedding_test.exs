defmodule FireflyWeb.EmbeddingTest do
  # Changes global config (which local addresses may be fetched).
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Discussion, Embedding, Repo, SiteSettings}
  alias Firefly.Discussion.Thread
  alias Firefly.Embedding.TopicEmbed
  alias Firefly.Plugins.HTTP

  # A blog with posts and a feed.
  defmodule Blog do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/posts/hello"} = conn, _opts) do
      html(conn, """
      <html><head><title>Fallback</title>
      <meta property="og:title" content="Hello, embedded world">
      <meta property="og:description" content="A post about embedding &amp; Firefly.">
      </head><body><p>Body</p></body></html>
      """)
    end

    def call(%Plug.Conn{request_path: "/posts/plain"} = conn, _opts) do
      html(conn, """
      <html><head><title>Plain post</title><script>var x = "<p>not this</p>";</script></head>
      <body><nav><p>Menu menu menu menu menu menu</p></nav>
      <article><p>The first paragraph of the article, long enough.</p><p>Short</p>
      <p>The second real paragraph &amp; more text here.</p></article></body></html>
      """)
    end

    def call(%Plug.Conn{request_path: "/feed.xml", port: port} = conn, _opts) do
      conn
      |> put_resp_content_type("application/rss+xml")
      |> send_resp(200, """
      <?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title>
      <item><title>From the feed</title><link>http://127.0.0.1:#{port}/posts/feed-one</link>
      <description><![CDATA[<p>Feed <b>summary</b></p>]]></description></item>
      <item><title>Elsewhere</title><link>https://other.example/post</link></item>
      </channel></rss>
      """)
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp html(conn, body), do: conn |> put_resp_content_type("text/html") |> send_resp(200, body)
  end

  setup do
    {:ok, server} = start_supervised({Bandit, plug: {Blog, nil}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    http = Application.get_env(:firefly, HTTP, [])
    Application.put_env(:firefly, HTTP, allow_private: [{127, 0, 0, 1}])
    on_exit(fn -> Application.put_env(:firefly, HTTP, http) end)

    admin = admin_fixture()
    category = category_fixture("Blog comments")

    {:ok, host} =
      Embedding.create_host(
        %{
          "host" => "http://127.0.0.1:#{port}/",
          "allowed_paths" => ["/posts/"],
          "category_id" => category.id,
          "class_name" => "blog",
          "tag" => "blog"
        },
        admin
      )

    {:ok, admin: admin, category: category, host: host, base: "http://127.0.0.1:#{port}"}
  end

  test "embed.js is served", %{conn: conn} do
    conn = get(conn, ~p"/embed.js")
    assert response(conn, 200) =~ "firefly-embed-resize"
    assert get_resp_header(conn, "content-type") == ["application/javascript; charset=utf-8"]
  end

  test "the first view makes the page's topic; the frame is allowed only for the hosts",
       %{conn: conn, base: base, category: category, host: host} do
    url = base <> "/posts/hello#comments"
    conn = get(conn, ~p"/embed/comments?embed_url=#{url}")
    html = html_response(conn, 200)

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'self' https://#{host.host} http://#{host.host};"
    assert get_resp_header(conn, "x-frame-options") == []

    assert html =~ "No replies yet"
    assert html =~ "Continue discussion"
    assert html =~ ~s(class="embed bg-transparent p-2 blog")
    assert html =~ "firefly-embed-resize"

    assert %TopicEmbed{thread_id: thread_id} =
             Repo.get_by(TopicEmbed, embed_url: base <> "/posts/hello")

    thread = Repo.preload(Repo.get!(Thread, thread_id), [:posts, :tags])
    assert thread.title == "Hello, embedded world"
    assert thread.category_id == category.id
    assert Enum.map(thread.tags, & &1.name) == ["blog"]
    assert hd(thread.posts).body =~ "> A post about embedding & Firefly."
    assert hd(thread.posts).body =~ "original entry at <#{base}/posts/hello>"

    # Replies show; the topic isn't made again.
    {:ok, _} = Discussion.create_post(thread, user_fixture(), %{body: "Great post!"})
    html = conn |> recycle() |> get(~p"/embed/comments?embed_url=#{url}") |> html_response(200)
    assert html =~ "Great post!"
    assert Repo.aggregate(TopicEmbed, :count) == 1

    html =
      conn |> recycle() |> get(~p"/embed/comments?topic_id=#{thread.id}") |> html_response(200)

    assert html =~ "Great post!"
  end

  test "other pages may only be framed by Firefly itself", %{conn: conn} do
    conn = get(conn, ~p"/categories")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'self';"
  end

  test "without OpenGraph, the title and first paragraphs", %{conn: conn, base: base} do
    get(conn, ~p"/embed/comments?embed_url=#{base <> "/posts/plain"}")
    %{thread_id: id} = Repo.get_by(TopicEmbed, embed_url: base <> "/posts/plain")
    thread = Repo.preload(Repo.get!(Thread, id), :posts)

    assert thread.title == "Plain post"
    body = hd(thread.posts).body
    assert body =~ "> The first paragraph of the article, long enough."
    assert body =~ "> The second real paragraph & more text here."
    refute body =~ "Menu"
    refute body =~ "not this"
  end

  test "pages that aren't on an embeddable host and path get nothing", %{conn: conn, base: base} do
    assert conn |> get(~p"/embed/comments?embed_url=https://evil.example/x") |> html_response(403) =~
             "isn&#39;t allowed"

    assert conn |> get(~p"/embed/comments?embed_url=#{base <> "/admin"}") |> html_response(403)
    assert conn |> get(~p"/embed/comments") |> html_response(400)
    assert Repo.aggregate(TopicEmbed, :count) == 0
  end

  test "fetching is SSRF-guarded: a host resolving to a private address is refused",
       %{conn: conn, base: base} do
    Application.put_env(:firefly, HTTP, allow_private: false)

    html =
      conn |> get(~p"/embed/comments?embed_url=#{base <> "/posts/hello"}") |> html_response(503)

    assert html =~ "couldn&#39;t be loaded"
    assert Repo.aggregate(TopicEmbed, :count) == 0
    assert {:error, {:fetch, _private}} = Embedding.fetch_page(base <> "/posts/hello")
  end

  test "the feed makes topics for new entries on embeddable hosts, once", %{
    admin: admin,
    base: base
  } do
    {:ok, _} = SiteSettings.update(%{"embed_feed_url" => base <> "/feed.xml"}, admin)

    assert :ok = Embedding.run_due()
    assert [%{embed_url: url, thread_id: id}] = Repo.all(TopicEmbed)
    assert url == base <> "/posts/feed-one"
    thread = Repo.preload(Repo.get!(Thread, id), :posts)
    assert thread.title == "From the feed"
    assert hd(thread.posts).body =~ "> Feed summary"

    assert {:ok, 0} = Embedding.poll_feed(base <> "/feed.xml")
  end

  test "topics are posted by the embed user setting", %{admin: admin, base: base} do
    writer = user_fixture()
    {:ok, _} = SiteSettings.update(%{"embed_username" => writer.username}, admin)
    {:ok, thread} = Embedding.topic_for_url(base <> "/posts/hello")
    assert hd(Repo.preload(thread, :posts).posts).user_id == writer.id

    {:ok, _} = SiteSettings.update(%{"embed_username" => "nobody-here"}, admin)
    assert {:error, :no_user} = Embedding.topic_for_url(base <> "/posts/plain")
  end

  test "admins manage hosts", %{conn: conn, admin: admin} do
    conn
    |> log_in_as(admin)
    |> visit(~p"/staff/embedding")
    |> assert_has("#hosts li", text: "127.0.0.1")
    |> assert_has("#snippet", text: "FireflyEmbed")
    |> fill_in("Host", with: "https://Blog.Example.com/")
    |> fill_in("Paths (optional: pages must start with one, e.g. /posts/)",
      with: "posts/ /notes/"
    )
    |> click_button("Add site")
    |> assert_has("#hosts li", text: "blog.example.com")
    |> assert_has("#hosts li", text: "/posts/, /notes/")
    |> fill_in("Host", with: "not a host!")
    |> click_button("Add site")
    |> assert_has("#host-form", text: "must be a host name")

    assert "https://blog.example.com" in Embedding.frame_ancestors()

    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/embedding")
    |> assert_path(~p"/")
  end
end
