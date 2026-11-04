defmodule FireflyWeb.SEO do
  @moduledoc """
  What each page tells search engines and link previews: the canonical
  URL, the meta description, OpenGraph and Twitter cards, `noindex` where
  it applies, and JSON-LD structured data.

  A page builds this with `assign/2` (a controller, LiveView or dead
  render), and the root layout renders it with `tags/1`. The root layout
  is rendered once, with the first (server-rendered) response, which is
  what crawlers and scrapers read; a live navigation updates the page
  title through `live_title`, not these tags.

  Site-wide defaults (the site's title and description, its icon as the
  preview image) fill in whatever a page leaves out, and the home page
  also describes the site itself (`WebSite` with a `SearchAction`, and
  `Organization`).
  """
  use Phoenix.Component

  alias Firefly.{SEO, SiteSettings, Uploads}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Post, Thread}
  alias Firefly.Moderation.WatchedWords

  # How many replies the structured data lists (the count is always exact).
  @max_comments 50

  @doc """
  Assigns the page's SEO data (see `tags/1`) on a socket or a conn.
  Keys, all optional: `:title`, `:description`, `:canonical` (a path or an
  absolute URL), `:image` (likewise), `:type` (`"website"`, the default,
  or `"article"`), `:published_at`, `:modified_at`, `:author` (a name),
  `:noindex` and `:json_ld` (a list of maps).
  """
  def assign(socket_or_conn, attrs \\ %{})

  def assign(%Plug.Conn{} = conn, attrs),
    do: Plug.Conn.assign(conn, :seo, Map.new(attrs))

  def assign(socket, attrs), do: Phoenix.Component.assign(socket, :seo, Map.new(attrs))

  @doc "The site's own structured data, for the home page."
  def site_json_ld do
    url = base_url()

    [
      %{
        "@context" => "https://schema.org",
        "@type" => "WebSite",
        "name" => SiteSettings.get("title"),
        "url" => url,
        "potentialAction" => %{
          "@type" => "SearchAction",
          "target" => %{
            "@type" => "EntryPoint",
            "urlTemplate" => "#{url}/search?q={search_term_string}"
          },
          "query-input" => "required name=search_term_string"
        }
      },
      %{
        "@context" => "https://schema.org",
        "@type" => "Organization",
        "name" => SiteSettings.get("title"),
        "url" => url,
        "logo" => absolute("/images/icon-512.png")
      }
    ]
  end

  @doc """
  A thread's SEO data: an article card with the first post's excerpt and
  first image, `DiscussionForumPosting` with its replies as comments, and
  a `BreadcrumbList` down to it. Threads in a restricted category (and, if
  the site says so, archived ones) are `noindex`.

  `posts` are the topic's posts, oldest first; at most `#{50}` replies
  are listed as comments.
  """
  def thread(%Thread{} = thread, %Category{} = category, posts) do
    [first | replies] = posts
    title = WatchedWords.censor(thread.title)

    %{
      title: title,
      description: SEO.excerpt(first.body),
      canonical: Firefly.URLs.thread_url(%{thread | category_id: category.id}),
      image: first_image(posts),
      type: "article",
      published_at: thread.inserted_at,
      modified_at: (List.last(posts) || first).inserted_at,
      author: author_name(first),
      noindex: not indexable_thread?(thread, category),
      json_ld: [
        discussion(thread, category, title, first, replies),
        breadcrumbs(thread, category, title)
      ]
    }
  end

  @doc "Whether a thread in `category` may be indexed: public, listed content only."
  def indexable_thread?(%Thread{} = thread, %Category{} = category) do
    SEO.indexable?() and not category.restricted and is_nil(thread.archived_at) and
      is_nil(thread.merged_into_id) and
      Firefly.Discussion.authorize(:view_thread, nil, thread) == :ok
  end

  defp discussion(thread, category, title, first, replies) do
    %{
      "@context" => "https://schema.org",
      "@type" => "DiscussionForumPosting",
      "headline" => title,
      "url" => Firefly.URLs.thread_url(%{thread | category_id: category.id}),
      "datePublished" => timestamp(thread.inserted_at),
      "articleSection" => category.title,
      "author" => author(first),
      "text" => SEO.excerpt(first.body, 500),
      "interactionStatistic" => %{
        "@type" => "InteractionCounter",
        "interactionType" => "https://schema.org/CommentAction",
        "userInteractionCount" => length(replies)
      },
      # A thousand-reply topic needn't ship a thousand comments: the
      # count is exact, the comments are the first @max_comments.
      "comment" => replies |> Enum.take(@max_comments) |> Enum.map(&comment/1)
    }
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp comment(post) do
    %{
      "@type" => "Comment",
      "datePublished" => timestamp(post.inserted_at),
      "author" => author(post),
      "text" => SEO.excerpt(post.body, 500)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp breadcrumbs(thread, category, title) do
    crumbs =
      [{SiteSettings.get("title"), base_url()}] ++
        [{category.title, Firefly.URLs.category_url(category)}] ++
        [{title, Firefly.URLs.thread_url(%{thread | category_id: category.id})}]

    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        for {{name, url}, position} <- Enum.with_index(crumbs, 1) do
          %{"@type" => "ListItem", "position" => position, "name" => name, "item" => url}
        end
    }
  end

  defp author(%Post{user: %User{} = user}) do
    %{"@type" => "Person", "name" => user.username, "url" => Firefly.URLs.user_url(user)}
  end

  defp author(_post), do: nil

  defp author_name(%Post{user: %User{} = user}), do: user.name || user.username
  defp author_name(_post), do: nil

  # The first image a post links to (see `Firefly.Uploads`), absolute.
  defp first_image(posts) do
    Enum.find_value(posts, fn post ->
      post.body |> Uploads.tokens() |> Enum.find_value(&image/1)
    end)
  end

  defp image(token) do
    case Uploads.get_by_token(token) do
      %{content_type: "image/" <> _} = upload -> absolute(Uploads.url(upload))
      _not_an_image -> nil
    end
  end

  @doc "Renders the page's tags; see the moduledoc. `seo` may be nil (the defaults)."
  attr :seo, :any, default: nil

  def tags(assigns) do
    assigns = assign(assigns, :seo, defaults(assigns.seo || %{}))

    ~H"""
    <link rel="canonical" href={@seo.canonical} />
    <meta :if={@seo.noindex} name="robots" content="noindex, follow" />
    <meta :if={@seo.description} name="description" content={@seo.description} />
    <meta property="og:site_name" content={@seo.site_name} />
    <meta property="og:type" content={@seo.type} />
    <meta property="og:title" content={@seo.title} />
    <meta property="og:url" content={@seo.canonical} />
    <meta :if={@seo.description} property="og:description" content={@seo.description} />
    <meta :if={@seo.image} property="og:image" content={@seo.image} />
    <meta :if={@seo.published_at} property="article:published_time" content={@seo.published_at} />
    <meta :if={@seo.modified_at} property="article:modified_time" content={@seo.modified_at} />
    <meta :if={@seo.author} property="article:author" content={@seo.author} />
    <meta name="twitter:card" content={if @seo.image, do: "summary_large_image", else: "summary"} />
    <meta name="twitter:title" content={@seo.title} />
    <meta :if={@seo.description} name="twitter:description" content={@seo.description} />
    <meta :if={@seo.image} name="twitter:image" content={@seo.image} />
    <script :for={data <- @seo.json_ld} type="application/ld+json">
      <%= Phoenix.HTML.raw(Jason.encode!(data, escape: :html_safe)) %>
    </script>
    """
  end

  # Nothing here is user input in an unsafe place: titles and excerpts go
  # into attributes (escaped by HEEx) and into JSON-LD encoded with
  # `escape: :html_safe`, so no `</script>` can come out of a post.
  defp defaults(seo) do
    site = SiteSettings.all()
    description = blank_to_nil(seo[:description]) || blank_to_nil(site["description"])

    %{
      site_name: site["title"],
      title: seo[:title] || site["title"],
      description: description,
      canonical: absolute(seo[:canonical] || "/"),
      image: absolute(seo[:image] || "/images/icon-512.png"),
      type: seo[:type] || "website",
      published_at: timestamp(seo[:published_at]),
      modified_at: timestamp(seo[:modified_at]),
      author: seo[:author],
      noindex: seo[:noindex] || not SEO.indexable?(),
      json_ld: seo[:json_ld] || []
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp absolute("http" <> _ = url), do: url
  defp absolute("/" <> _ = path), do: base_url() <> path

  defp base_url, do: String.trim_trailing(FireflyWeb.Endpoint.url(), "/")

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp timestamp(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
