defmodule Firefly.SEO do
  @moduledoc """
  The SEO context: what search engines are told about the forum.

  It answers three questions, all about public content only (anything a
  visitor can't read is never named here):

    * `robots_txt/0` - the `robots.txt` body: the crawl rules, the
      staff, admin and account paths that are always disallowed, the
      admin's extra rules (the `robots_extra` site setting) and a link
      to the sitemap. With indexing off (`allow_indexing`) it disallows
      everything instead.
    * `sitemaps/0` and `sitemap/1` - the sitemap index and each of its
      sitemaps: public topics (paginated, `#{25_000}` URLs each, as
      the protocol's 50,000 limit allows), categories and tags, each
      entry with its last change.
    * `excerpt/2` - a post's or a text's first words as plain text, for
      meta descriptions and structured data.

  The web interface renders these (`FireflyWeb.SitemapController`,
  `FireflyWeb.SEO`); page metadata (canonical URLs, OpenGraph, JSON-LD)
  is built there, from what each page already loaded.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Sitemap]

  alias Firefly.SEO.Sitemap
  alias Firefly.SiteSettings

  @doc "Whether search engines may index the forum (the `allow_indexing` setting)."
  def indexable?, do: SiteSettings.get("allow_indexing")

  @doc """
  Whether members' pages (profiles, the directory, groups, badges) may be
  indexed (the `index_user_pages` setting); they're a crawl trap on a
  large forum, and public but personal.
  """
  def index_user_pages?, do: indexable?() and SiteSettings.get("index_user_pages")

  @doc "Paths no crawler should follow, indexing on or off."
  def disallowed_paths do
    ~w(/staff/ /admin/ /settings/ /messages/ /chat/ /notifications/ /bookmarks/ /drafts/
       /invites/ /api/ /mcp /auth/ /login /register /reset-password /confirm/ /email/
       /search?)
  end

  @doc "The `robots.txt` body (see the moduledoc)."
  def robots_txt do
    sitemap = "Sitemap: #{Firefly.Endpoint.url()}/sitemap.xml"
    extra = String.trim(to_string(SiteSettings.get("robots_extra")))

    lines =
      if indexable?() do
        ["User-agent: *" | Enum.map(disallowed_paths(), &"Disallow: #{&1}")]
      else
        ["# Indexing is off in the site settings.", "User-agent: *", "Disallow: /"]
      end

    ([Enum.join(lines, "\n")] ++ [extra] ++ [sitemap])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc "The sitemaps the index lists: `%{name, lastmod}` (empty with indexing off)."
  def sitemaps, do: if(indexable?(), do: Sitemap.index(), else: [])

  @doc """
  One sitemap's entries (`%{loc, lastmod}`), by name as `sitemaps/0`
  gives it: `\"categories\"`, `\"tags\"` or `\"topics-<page>\"`. An
  unknown name, or indexing off, is `:error`.
  """
  def sitemap(name), do: if(indexable?(), do: Sitemap.entries(name), else: :error)

  @doc """
  `text` (Markdown, as members write it) as one line of plain text, at
  most `length` characters (160 by default, what search results show),
  cut at a word boundary. Nil or blank text gives nil.
  """
  def excerpt(text, length \\ 160)
  def excerpt(nil, _length), do: nil

  def excerpt(text, length) do
    text
    |> strip_markup()
    |> case do
      "" -> nil
      stripped -> truncate(stripped, length)
    end
  end

  # Enough to read as prose: images, links, code fences, quotes, headings
  # and emphasis go; link text stays.
  defp strip_markup(text) do
    text
    |> String.replace(~r/```.*?```/s, " ")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, " ")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/[#*_`~>|]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, length) do
    if String.length(text) <= length do
      text
    else
      text
      |> String.slice(0, length - 1)
      |> String.replace(~r/\s+\S*$/, "")
      |> Kernel.<>("…")
    end
  end
end
