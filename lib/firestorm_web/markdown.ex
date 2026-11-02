defmodule FirestormWeb.Markdown do
  @moduledoc """
  Render a string as markdown in the FirestormWeb style, then sanitize the
  resulting HTML.

  Rendering is done by `MDEx` (CommonMark + GitHub Flavored Markdown) with:

    * bare URL autolinking
    * emoji shortcodes (i.e. `:poop:`) replaced with their emoji counterpart
    * soft line breaks rendered as `<br>`
    * `<pre class="line-numbers">` code blocks with `language-*` classes, for
      proper support from https://prismjs.com/plugins/line-numbers/

  Quote replies (a blockquote starting with a `[@user said:](url)` link, see
  `FirestormWeb.Quote`) get a `quote` class and an attribution header.

  `@username` mentions and `#category-slug` references that name an existing
  user or category link to them (see `FirestormWeb.Mentions`); a restricted
  category only links for a `viewer` who may read it (without one, as in
  emails and the API, only categories everyone can read link). Rendering
  several posts, pass `Mentions.refs/2` of all their bodies to `render/2`
  instead of the viewer, so the names are looked up once.

  Raw HTML is allowed in the input, but the output is always run through an
  allow-list sanitizer, so scripts, event handlers and `javascript:` URLs are
  stripped.

  A post's body (rendered with the `:post` and `:thread` options) also goes
  through the plugins' content hooks (see `FirestormWeb.Plugins.Content`),
  whose output is sanitized again.
  """

  alias FirestormWeb.Mentions

  @options [
    extension: [
      autolink: true,
      strikethrough: true,
      table: true,
      tagfilter: true,
      shortcodes: true
    ],
    parse: [smart: false],
    render: [hardbreaks: true, unsafe: true],
    syntax_highlight: nil,
    sanitize: MDEx.Document.default_sanitize_options()
  ]

  # A quote reply's attribution: a blockquote that starts with a link reading
  # "@user said:" (see `FirestormWeb.Quote`).
  @quote_header ~r{<blockquote>\n<p>(<a href="[^"]*"[^>]*>@[^<]+ said:</a>)</p>}

  @doc false
  def options, do: @options

  @spec render(String.t() | nil, Mentions.refs() | term, keyword) :: String.t()
  def render(body, refs_or_viewer \\ nil, opts \\ [])

  def render(nil, _refs_or_viewer, _opts), do: ""

  def render(body, refs_or_viewer, opts) when is_binary(body) do
    body
    |> Mentions.parse()
    |> Mentions.link(refs_or_viewer)
    |> MDEx.to_html!(@options)
    |> plugins(opts[:post], opts[:thread])
    # Safe to do after sanitizing: any literal `<pre>` in user text is escaped.
    |> String.replace("<pre>", ~s(<pre class="line-numbers">))
    |> String.replace(
      @quote_header,
      ~s(<blockquote class="quote">\n<p class="quote-attribution">\\1</p>)
    )
  end

  defp plugins(html, nil, _thread), do: html
  defp plugins(html, post, thread), do: FirestormWeb.Plugins.Content.transform(html, post, thread)
end
