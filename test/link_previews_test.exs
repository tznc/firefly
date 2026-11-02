defmodule FirestormWeb.LinkPreviewsTest do
  # Changes global config (fetching on, which local addresses are allowed).
  use FirestormWeb.Web.ConnCase, async: false

  alias FirestormWeb.{Forums, LinkPreviews, Repo, SiteSettings, Uploads}
  alias FirestormWeb.LinkPreviews.{Fetcher, LinkPreview, Parser}
  alias FirestormWeb.Plugins.HTTP

  # A small website to preview.
  defmodule Site do
    @moduledoc false
    import Plug.Conn

    @page """
    <!doctype html><html><head>
    <title>Fallback title</title>
    <meta property="og:title" content="Supervisors &amp; you">
    <meta property="og:description" content="<b>Let</b> it&#32;crash. <script>alert(1)</script>">
    <meta property="og:site_name" content="Elixir Blog">
    <meta property="og:image" content="/image.png">
    </head><body>Hello</body></html>
    """

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/page"} = conn, _opts), do: html(conn, @page)

    def call(%Plug.Conn{request_path: "/plain"} = conn, _opts),
      do: html(conn, "<html><head><title>Just a title</title></head></html>")

    def call(%Plug.Conn{request_path: "/xss"} = conn, _opts) do
      html(conn, """
      <head><meta property="og:title" content="&quot;&gt;&lt;img src=x onerror=alert(1)&gt;">
      <meta property="og:image" content="javascript:alert(1)"></head>
      """)
    end

    def call(%Plug.Conn{request_path: "/image.png"} = conn, _opts) do
      png = 800 |> Image.new!(400, color: :blue) |> Image.write!(:memory, suffix: ".png")
      conn |> put_resp_content_type("image/png") |> send_resp(200, png)
    end

    def call(%Plug.Conn{request_path: "/redirect"} = conn, _opts), do: redirect(conn, "/page")

    def call(%Plug.Conn{request_path: "/to-private"} = conn, _opts),
      do: redirect(conn, "http://10.0.0.1/page")

    def call(%Plug.Conn{request_path: "/loop"} = conn, _opts), do: redirect(conn, "/loop")

    def call(%Plug.Conn{request_path: "/json"} = conn, _opts),
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, ~s({"a": 1}))

    def call(%Plug.Conn{request_path: "/huge"} = conn, _opts),
      do: html(conn, String.duplicate("<p>spam</p>", 300_000))

    def call(conn, _opts), do: send_resp(conn, 404, "not found")

    defp html(conn, body), do: conn |> put_resp_content_type("text/html") |> send_resp(200, body)

    defp redirect(conn, to),
      do: conn |> put_resp_header("location", to) |> send_resp(302, "")
  end

  setup do
    {:ok, server} = start_supervised({Bandit, plug: Site, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    http = Application.get_env(:firestorm_web, HTTP, [])
    previews = Application.get_env(:firestorm_web, LinkPreviews, [])
    Application.put_env(:firestorm_web, HTTP, allow_private: [{127, 0, 0, 1}])
    Application.put_env(:firestorm_web, LinkPreviews, enabled: true)

    on_exit(fn ->
      Application.put_env(:firestorm_web, HTTP, http)
      Application.put_env(:firestorm_web, LinkPreviews, previews)
    end)

    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  describe "which links" do
    test "bare links alone on their line, not in code or with other text" do
      body = """
      https://example.com/alone

      Look: https://example.com/inline and [named](https://example.com/named)
      first line
      https://example.com/own-line

          https://example.com/code

      `https://example.com/inline-code`

      https://www.youtube.com/watch?v=abc

      https://example.com/alone
      """

      assert LinkPreviews.urls(body) == [
               "https://example.com/alone",
               "https://example.com/own-line"
             ]
    end

    test "at most five per post" do
      body = Enum.map_join(1..8, "\n\n", &"https://example.com/#{&1}")
      assert length(LinkPreviews.urls(body)) == 5
    end
  end

  describe "fetching" do
    test "follows redirects to a page and reads its card", %{base: base} do
      assert {:ok, page} =
               Fetcher.get(base <> "/redirect", types: ["text/html"], max_bytes: 100_000)

      assert page.url == base <> "/page"

      assert Parser.parse(page.body, page.url) == %{
               title: "Supervisors & you",
               description: "Let it crash. alert(1)",
               site_name: "Elixir Blog",
               image: base <> "/image.png"
             }
    end

    test "falls back to the title" do
      assert %{title: "Just a title", description: nil, image: nil} =
               Parser.parse("<title>Just a title</title>", "https://a.example/")
    end

    test "only public addresses, checked again after each redirect", %{base: base} do
      Application.put_env(:firestorm_web, HTTP, allow_private: false)

      assert {:error, "127.0.0.1 resolves to a private address"} =
               Fetcher.get(base <> "/page", types: ["text/html"], max_bytes: 100_000)

      Application.put_env(:firestorm_web, HTTP, allow_private: [{127, 0, 0, 1}])

      assert {:error, "10.0.0.1 resolves to a private address"} =
               Fetcher.get(base <> "/to-private", types: ["text/html"], max_bytes: 100_000)

      assert {:error, :too_many_redirects} =
               Fetcher.get(base <> "/loop", types: ["text/html"], max_bytes: 100_000)

      assert {:error, :scheme} =
               Fetcher.get("file:///etc/passwd", types: ["text/html"], max_bytes: 100)
    end

    test "only HTML, and not too much of it", %{base: base} do
      assert {:error, {:content_type, "application/json"}} =
               Fetcher.get(base <> "/json", types: ["text/html"], max_bytes: 100_000)

      assert {:error, _too_large} =
               Fetcher.get(base <> "/huge", types: ["text/html"], max_bytes: 100_000)
    end
  end

  defp thread_with(body) do
    user = user_fixture()
    thread = thread_fixture(category_fixture(), user)
    :ok = Forums.subscribe("forums:thread:#{thread.id}")
    {:ok, post} = Forums.create_post(thread, user, %{body: body})
    {thread, post}
  end

  describe "previews" do
    test "are fetched after posting, cached, and shown live", %{conn: conn, base: base} do
      user = user_fixture()
      thread = thread_fixture(category_fixture(), user)
      path = ~p"/categories/#{thread.category_id}/threads/#{thread}"
      session = visit(conn, path)

      :ok = Forums.subscribe("forums:thread:#{thread.id}")
      {:ok, _post} = Forums.create_post(thread, user, %{body: "Read this:\n\n#{base}/page"})
      thread_id = thread.id
      assert_receive {:link_previews_ready, ^thread_id}, 5_000

      preview = Repo.get_by!(LinkPreview, url: base <> "/page") |> Repo.preload(:image_upload)
      assert preview.status == "ok"
      assert preview.title == "Supervisors & you"
      # The image is a scaled copy in uploads.
      assert preview.image_upload.attached_to == "preview"
      assert preview.image_upload.width == 640
      assert DateTime.diff(preview.expires_at, DateTime.utc_now(), :hour) in 167..168

      session
      |> assert_has(".link-preview a[href='#{base}/page']", text: "Supervisors & you")
      |> assert_has(".link-preview", text: "Elixir Blog")
      |> assert_has(".link-preview img[src='#{Uploads.url(preview.image_upload)}']")

      # Cached: a fresh preview isn't claimed again.
      refute LinkPreviews.claim(base <> "/page")
    end

    test "page values are text, and other sites' images are never linked", %{base: base} do
      {_thread, _post} = thread_with("#{base}/xss")
      assert_receive {:link_previews_ready, _}, 5_000

      preview = Repo.get_by!(LinkPreview, url: base <> "/xss")
      assert preview.title == "\">"
      refute preview.image_upload_id

      html =
        Phoenix.LiveViewTest.rendered_to_string(
          FirestormWeb.Web.ForumComponents.link_preview(%{
            preview: Repo.preload(preview, :image_upload)
          })
        )

      refute html =~ "<img"
      refute html =~ "onerror"
    end

    test "a page without a title is remembered as failed, and shows nothing", %{base: base} do
      {thread, _post} = thread_with("#{base}/json")
      assert_receive {:link_previews_ready, _}, 5_000

      assert %LinkPreview{status: "failed", title: nil} =
               Repo.get_by!(LinkPreview, url: base <> "/json")

      [post | _] = Repo.preload(thread, :posts, force: true).posts |> Enum.reverse()
      assert [%{link_previews: []}] = LinkPreviews.decorate([post])
    end

    test "the site setting turns them off", %{base: base} do
      {:ok, _} = SiteSettings.update(%{"link_previews" => "false"}, admin_fixture())
      thread_with("#{base}/page")

      refute_receive {:link_previews_ready, _}, 300
      refute Repo.get_by(LinkPreview, url: base <> "/page")
    end

    test "unseen previews are deleted with their images", %{base: base} do
      thread_with("#{base}/page")
      assert_receive {:link_previews_ready, _}, 5_000
      preview = Repo.get_by!(LinkPreview, url: base <> "/page")

      assert LinkPreviews.run_due() == 0
      assert LinkPreviews.run_due(DateTime.add(DateTime.utc_now(), 40, :day)) == 1
      refute Repo.reload(preview)
      refute Repo.get(Uploads.Upload, preview.image_upload_id)
    end
  end
end
