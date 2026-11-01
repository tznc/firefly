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

  Raw HTML is allowed in the input, but the output is always run through an
  allow-list sanitizer, so scripts, event handlers and `javascript:` URLs are
  stripped.
  """

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

  @spec render(String.t() | nil) :: String.t()
  def render(nil), do: ""

  def render(body) when is_binary(body) do
    body
    |> MDEx.to_html!(@options)
    # Safe to do after sanitizing: any literal `<pre>` in user text is escaped.
    |> String.replace("<pre>", ~s(<pre class="line-numbers">))
    |> String.replace(
      @quote_header,
      ~s(<blockquote class="quote">\n<p class="quote-attribution">\\1</p>)
    )
  end
end
