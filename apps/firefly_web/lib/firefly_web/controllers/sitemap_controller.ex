defmodule FireflyWeb.SitemapController do
  @moduledoc """
  `robots.txt` and the sitemaps (see `Firefly.SEO`): `/sitemap.xml` is the
  index of `/sitemap/<name>.xml`, each listing public content with its
  last change. Both are cached by clients for an hour; with indexing off
  the index is empty and the sitemaps are `404`.
  """
  use FireflyWeb, :controller

  alias Firefly.SEO

  def robots(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> cache()
    |> send_resp(200, SEO.robots_txt())
  end

  def index(conn, _params) do
    sitemaps =
      for %{name: name, lastmod: lastmod} <- SEO.sitemaps() do
        """
          <sitemap>
            <loc>#{url(~p"/sitemap/#{name <> ".xml"}")}</loc>
            <lastmod>#{DateTime.to_iso8601(lastmod)}</lastmod>
          </sitemap>
        """
      end

    xml(conn, """
    <?xml version="1.0" encoding="UTF-8"?>
    <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{sitemaps}</sitemapindex>
    """)
  end

  def show(conn, %{"name" => name}) do
    case name |> String.trim_trailing(".xml") |> SEO.sitemap() do
      {:ok, entries} -> xml(conn, urlset(entries))
      :error -> conn |> put_status(404) |> text("No such sitemap.")
    end
  end

  defp urlset(entries) do
    urls =
      for %{loc: loc, lastmod: lastmod} <- entries do
        """
          <url>
            <loc>#{escape(loc)}</loc>
            <lastmod>#{DateTime.to_iso8601(lastmod)}</lastmod>
          </url>
        """
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{urls}</urlset>
    """
  end

  defp xml(conn, body) do
    conn
    |> put_resp_content_type("application/xml")
    |> cache()
    |> send_resp(200, body)
  end

  defp cache(conn), do: put_resp_header(conn, "cache-control", "public, max-age=3600")

  # Sitemap URLs are XML text: escape what XML reserves (tags' names and
  # titles can hold &, < and >).
  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
