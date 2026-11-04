defmodule Firefly.Rendering.Markdown do
  @moduledoc """
  Render a string as markdown in the Firefly style, then sanitize the
  resulting HTML.

  Rendering is done by `MDEx` (CommonMark + GitHub Flavored Markdown) with:

    * bare URL autolinking
    * emoji shortcodes (i.e. `:poop:`) replaced with their emoji counterpart
    * soft line breaks rendered as `<br>`
    * `<pre class="line-numbers">` code blocks with `language-*` classes, for
      proper support from https://prismjs.com/plugins/line-numbers/

  Quote replies (a blockquote starting with a `[@user said:](url)` link, see
  `Firefly.Discussion.Quote`) get a `quote` class and an attribution header.

  `@username` mentions and `#category-slug` references that name an existing
  user or category link to them (see `Firefly.Discussion.Mentions`); a restricted
  category only links for a `viewer` who may read it (without one, as in
  emails and the API, only categories everyone can read link). Rendering
  several posts, pass `Mentions.refs/2` of all their bodies to `render/2`
  instead of the viewer, so the names are looked up once.

  BBCode (see `Firefly.Rendering.BBCode`, the `bbcode` site setting) is
  converted to Markdown first.

  Each of these has a site setting to turn it off:

    * spoilers: `>!text!<` and `[spoiler]` become `<span class="spoiler">`
      (`<div>` when spanning paragraphs), hidden until clicked
    * math: `$...$` and `$$...$$` become `<span data-math-style>`, typeset
      in the browser by the vendored KaTeX (`priv/static/vendor/katex`)
    * footnotes: `[^name]` references and `[^name]: text` definitions.
      Their ids are scoped to the post (several posts' footnotes share a
      page) and prefixed `user-content-`, as every id in a post is, so
      no post can clash with the page's own ids

  Custom emoji (see `Firefly.Rendering.Emoji`) written `:name:` become
  `<img class="emoji">` (not in code).

  Watched words (see `Firefly.Moderation.WatchedWords`) are replaced,
  censored and linked in text (not in code).

  Raw HTML is allowed in the input, but the output is always run through an
  allow-list sanitizer (`sanitize_options/0`: MDEx's defaults plus only what
  the steps above need: the `emoji` class on images, `data-math-style`
  set to `inline` or `display` on spans, `<section>` and `id`s on links
  and list items for footnotes), so scripts, event handlers and
  `javascript:` URLs are stripped. Inline styles are dropped too
  (`safe_styles/1`), except BBCode's color and size: a post can't restyle
  or cover the page.

  A post's body (rendered with the `:post` and `:thread` options) also goes
  through the plugins' content hooks (see `Firefly.Plugins.Content`),
  whose output is sanitized again.
  """

  alias Firefly.SiteSettings
  alias Firefly.Discussion.Mentions
  alias Firefly.Moderation.WatchedWords
  alias Firefly.Rendering.{BBCode, Emoji}

  @sanitize MDEx.Document.default_sanitize_options()
            |> Keyword.merge(
              # Custom emoji: `class` on images may only be "emoji".
              add_allowed_classes: %{"img" => ["emoji"]},
              # Math: only these two values.
              add_tag_attribute_values: %{
                "span" => %{"data-math-style" => ["inline", "display"]}
              },
              # Footnotes: the list's section, and the anchors' ids,
              # always prefixed so they can't clash with the page's.
              add_tags: ["section"],
              add_tag_attributes: %{"a" => ["id"], "li" => ["id"]},
              id_prefix: "user-content-"
            )

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
    sanitize: @sanitize
  ]

  # A quote reply's attribution: a blockquote that starts with a link reading
  # "@user said:" (see `Firefly.Discussion.Quote`).
  @quote_header ~r{<blockquote>\n<p>(<a href="[^"]*"[^>]*>@[^<]+ said:</a>)</p>}

  # The styles BBCode writes (see Firefly.Rendering.BBCode): a named or
  # hex color, a font size in percent.
  @bbcode_style ~r/\A(?:color: (?:#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|[a-z]+)|font-size: [0-9]{2,3}%)\z/

  @doc "The MDEx options, with the extensions the site settings turn on."
  def options do
    @options
    |> put_in([:extension, :math_dollars], SiteSettings.get("math"))
    |> put_in([:extension, :footnotes], SiteSettings.get("footnotes"))
  end

  @doc """
  The sanitizer allow-list for post HTML, also applied to what plugins
  return (see `Firefly.Plugins.Content.sanitize/1`).
  """
  def sanitize_options, do: @sanitize

  @doc """
  Sanitized `html` without its `style` attributes, but for BBCode's
  colors and sizes. MDEx's allow-list keeps `style` on `div`, `span`,
  `pre` and `code` (for its syntax highlighting), and the page's CSP
  allows inline styles, so a post could otherwise cover the whole page
  (`position: fixed`) with lookalike content. Only for sanitized HTML,
  where a quote is always the end of an attribute.
  """
  def safe_styles(html) do
    if String.contains?(html, " style=\""),
      do: Regex.replace(~r/ style="([^"]*)"/, html, &bbcode_style/2),
      else: html
  end

  defp bbcode_style(attribute, style), do: if(style =~ @bbcode_style, do: attribute, else: "")

  @spec render(String.t() | nil, Mentions.refs() | term, keyword) :: String.t()
  def render(body, refs_or_viewer \\ nil, opts \\ [])

  def render(nil, _refs_or_viewer, _opts), do: ""

  def render(body, refs_or_viewer, opts) when is_binary(body) do
    spoilers? = SiteSettings.get("spoilers")
    options = options()

    # The parser only takes UTF-8 (forms can send anything).
    body
    |> String.replace_invalid()
    |> bbcode(spoilers?)
    |> spoilers(spoilers?)
    |> Mentions.parse()
    |> Mentions.link(refs_or_viewer)
    |> watched_words(WatchedWords.matchers())
    |> custom_emoji(Emoji.custom())
    |> footnotes(opts[:post])
    |> MDEx.to_html!(options)
    |> safe_styles()
    |> footnote_links()
    |> plugins(opts[:post], opts[:thread])
    # Safe to do after sanitizing: any literal `<pre>` in user text is escaped.
    |> String.replace("<pre>", ~s(<pre class="line-numbers">))
    |> String.replace(
      @quote_header,
      ~s(<blockquote class="quote">\n<p class="quote-attribution">\\1</p>)
    )
  end

  # Only replace, censor and link words change how text renders.
  defp watched_words(document, matchers) do
    if Enum.any?(~w(replace censor link), &Map.has_key?(matchers, &1)),
      do: watched_in(document, true, matchers),
      else: document
  end

  # No links inside links (or image descriptions).
  defp watched_in(%{nodes: nodes} = node, links?, matchers) do
    links? = links? and not is_struct(node, MDEx.Link) and not is_struct(node, MDEx.Image)
    %{node | nodes: Enum.flat_map(nodes, &watched_nodes(&1, links?, matchers))}
  end

  defp watched_in(node, _links?, _matchers), do: node

  defp watched_nodes(%MDEx.Text{literal: text}, links?, matchers) do
    Enum.map(WatchedWords.render_text(text, links?, matchers), fn
      {:text, text} -> %MDEx.Text{literal: text}
      {:link, text, url} -> %MDEx.Link{url: url, title: "", nodes: [%MDEx.Text{literal: text}]}
    end)
  end

  defp watched_nodes(node, links?, matchers), do: [watched_in(node, links?, matchers)]

  @emoji_name ~r/:([a-z0-9_]{2,32}):/

  # Text nodes (code is literal, not text) with `:name:` of a custom emoji
  # are split around an <img> for it.
  defp custom_emoji(document, emoji) when emoji == %{}, do: document

  defp custom_emoji(document, emoji) do
    MDEx.traverse_and_update(document, fn
      %{nodes: [_ | _] = nodes} = node ->
        %{node | nodes: Enum.flat_map(nodes, &emoji_text(&1, emoji))}

      node ->
        node
    end)
  end

  defp emoji_text(%MDEx.Text{literal: text} = node, emoji) do
    if String.contains?(text, ":") do
      @emoji_name
      |> Regex.split(text, include_captures: true)
      |> Enum.map(&emoji_part(&1, emoji))
    else
      [node]
    end
  end

  defp emoji_text(node, _emoji), do: [node]

  defp emoji_part(part, emoji) do
    with [_, name] <- Regex.run(~r/\A:([a-z0-9_]{2,32}):\z/, part),
         {:ok, url} <- Map.fetch(emoji, name) do
      %MDEx.HtmlInline{literal: emoji_img(name, url)}
    else
      _text -> %MDEx.Text{literal: part}
    end
  end

  defp emoji_img(name, url),
    do: ~s(<img class="emoji" src="#{escape(url)}" alt=":#{name}:" title=":#{name}:">)

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # A shortcode an active plugin declares (see Firefly.Plugins.Content)
  # is the plugin's, even when BBCode has a tag of that name.
  defp bbcode(body, spoilers?) do
    skip =
      Firefly.Plugins.Content.shortcode_names() ++ if(spoilers?, do: [], else: ["spoiler"])

    if SiteSettings.get("bbcode"), do: BBCode.to_markdown(body, skip), else: body
  end

  # `>!text!<` on one line, outside code.
  defp spoilers(body, false), do: body

  defp spoilers(body, true) do
    if String.contains?(body, ">!") do
      BBCode.outside_code(body, fn text ->
        Regex.replace(~r/>!(?=\S)(.+?)(?<=\S)!</, text, ~s(<span class="spoiler">\\1</span>))
      end)
    else
      body
    end
  end

  # Footnote names get the post's id (or "preview"), so two posts on one
  # page don't share anchors.
  defp footnotes(document, post) do
    scope = if post, do: "p#{post.id}", else: "preview"

    MDEx.traverse_and_update(document, fn
      %MDEx.FootnoteReference{name: name} = node -> %{node | name: "#{scope}-#{name}"}
      %MDEx.FootnoteDefinition{name: name} = node -> %{node | name: "#{scope}-#{name}"}
      node -> node
    end)
  end

  # The sanitizer prefixed the footnotes' ids; their links follow.
  defp footnote_links(html),
    do:
      String.replace(
        html,
        [~s(href="#fn-), ~s(href="#fnref-)],
        &String.replace(&1, "#", "#user-content-")
      )

  defp plugins(html, nil, _thread), do: html
  defp plugins(html, post, thread), do: Firefly.Plugins.Content.transform(html, post, thread)
end
