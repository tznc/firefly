defmodule Firefly.Generators do
  @moduledoc """
  `StreamData` generators shared by the property-based and fuzz tests of
  every app (`import Firefly.Generators`; see "Tests" in the README).

  Two families:

    * valid domain data: usernames, emails, titles, post bodies, tags,
      colors, versions, plugin and theme manifests
    * adversarial input: unicode (RTL and zero-width marks, combining
      characters, emoji), control characters, very long strings, invalid
      UTF-8, nested and malformed markup, script and event-handler vectors,
      `javascript:` URLs in their many spellings, path traversal, huge
      numbers

  Run counts: properties use `runs/1` (a modest default, raised with
  `FIREFLY_PROPERTY_RUNS`); the deep fuzz tests, tagged `:fuzz` and left
  out of a plain `mix test`, use `fuzz_runs/0` (`FIREFLY_FUZZ_RUNS`,
  default 5000).
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  import StreamData

  ## Run counts

  @doc "Runs for a regular property: `default`, or `FIREFLY_PROPERTY_RUNS`."
  def runs(default \\ 50), do: env_integer("FIREFLY_PROPERTY_RUNS", default)

  @doc "Runs for a deep `:fuzz` property: `FIREFLY_FUZZ_RUNS`, default 5000."
  def fuzz_runs, do: env_integer("FIREFLY_FUZZ_RUNS", 5_000)

  defp env_integer(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  ## Adversarial text

  @zero_width ["\u200B", "\u200C", "\u200D", "\u2060", "\uFEFF", "\u00AD"]
  @bidi [
    "\u200E",
    "\u200F",
    "\u202A",
    "\u202B",
    "\u202C",
    "\u202D",
    "\u202E",
    "\u2066",
    "\u2067",
    "\u2068",
    "\u2069",
    "\u061C"
  ]
  @combining ["\u0301", "\u0308", "\u0338", "\u20DD", "\u0489"]
  @odd_letters ["İ", "ı", "ß", "ẞ", "ſ", "K", "Å", "ﬁ", "ǅ", "Σ", "ς", "Ω", "ǰ", "ŉ"]
  @emoji ["🔥", "👩‍👩‍👧‍👦", "🏳️‍🌈", "👍🏽", "🇸🇬", "❤️", "1️⃣"]
  @scripts ["日本語", "עברית", "العربية", "русский", "ελληνικά", "한국어", "ไทย", "हिन्दी"]
  @control Enum.map(Enum.to_list(0..31) ++ [127], &<<&1>>)
  @c1 Enum.map(0x80..0x9F, &<<&1::utf8>>)
  @specials [
    "\u2028",
    "\u2029",
    "\u0085",
    "\u000C",
    "\uFFFD",
    "\uFFFF",
    "\u{10FFFF}",
    "\u{E0001}",
    "\u{1D400}"
  ]
  @traversal [
    "../",
    "..\\",
    "../../etc/passwd",
    "..%2f",
    "%2e%2e/",
    "....//",
    "/etc/passwd",
    "C:\\Windows\\",
    "\\\\server\\share",
    "./",
    "~/",
    "a/../../b",
    "..",
    "."
  ]
  @numbers [
    "0",
    "-0",
    "-1",
    "1e999",
    "-1e999",
    "NaN",
    "Infinity",
    "0x10",
    "1_000",
    "+5",
    " 7 ",
    "٣",
    "１２",
    String.duplicate("9", 400),
    "-" <> String.duplicate("9", 400),
    "9223372036854775808",
    "-9223372036854775809",
    "18446744073709551616",
    "1.5",
    "1,5"
  ]

  @doc "Numbers as text: huge, negative, signed, non-ASCII digits, floats..."
  def numbers, do: @numbers

  @doc "One adversarial snippet: a mark, control character, traversal, number..."
  def adversarial_snippet do
    one_of([
      member_of(@zero_width),
      member_of(@bidi),
      member_of(@combining),
      member_of(@odd_letters),
      member_of(@emoji),
      member_of(@scripts),
      member_of(@control),
      member_of(@c1),
      member_of(@specials),
      member_of(@traversal),
      member_of(@numbers),
      member_of(~w(< > & " ' ` = / \\ ; : { } [ ] \( \) * _ ~ # @ ! | $ % ^ + -))
    ])
  end

  @doc """
  Text built from ordinary and adversarial pieces: valid UTF-8, of up to
  about `max` pieces.
  """
  def adversarial_text(max \\ 30) do
    [string(:printable, max_length: 12), string(:utf8, max_length: 6), adversarial_snippet()]
    |> one_of()
    |> list_of(max_length: max)
    |> map(&Enum.join/1)
  end

  @doc "A very long string: `piece` repeated up to `max_bytes`."
  def long_string(max_bytes \\ 200_000) do
    bind(one_of([adversarial_snippet(), string(:alphanumeric, min_length: 1)]), fn piece ->
      map(integer(1..max(div(max_bytes, max(byte_size(piece), 1)), 1)), fn n ->
        String.duplicate(piece, n)
      end)
    end)
  end

  @doc "Any binary at all, invalid UTF-8 included."
  def any_binary(max \\ 200), do: binary(max_length: max)

  @doc "Strings of every kind: ordinary, adversarial, long, and invalid UTF-8."
  def any_text do
    frequency([
      {6, adversarial_text()},
      {2, string(:printable)},
      {1, member_of(["", " ", "\n", "\t"])},
      {1, any_binary()}
    ])
  end

  ## Markup

  # Tags a sanitizer must take out (with their contents, or at least their
  # behavior), and tags it may keep.
  @dangerous_tags ~w(script style iframe object embed form input button textarea select
                     base meta link svg math template frame frameset applet noscript
                     xmp plaintext noembed portal dialog video audio source)
  @benign_tags ~w(p div span a img b i em strong u s code pre blockquote ul ol li table
                  tr td th h1 h2 h3 details summary sup sub br hr section)

  @event_attributes ~w(onerror onload onclick onmouseover onfocus onanimationstart
                       onbegin onpointerenter ontoggle onbeforeprint OnErRoR)

  @doc "`javascript:` (and other script-running) URLs, in their many spellings."
  def script_url do
    payload = member_of(["alert(1)", "alert`1`", "fetch('//x')", "eval(name)"])

    scheme =
      member_of([
        "javascript:",
        "JaVaScRiPt:",
        " javascript:",
        "\tjavascript:",
        "java\tscript:",
        "java\nscript:",
        "java\rscript:",
        "\u0000javascript:",
        "\u0001javascript:",
        "javascript&colon;",
        "javascript&#58;",
        "javascript&#x3A;",
        "&#106;avascript:",
        "&#x6A;avascript:",
        "&#0000106;avascript:",
        "jav&#x09;ascript:",
        "jav&#9;ascript:",
        "java&NewLine;script:",
        "vbscript:",
        "VBScript:",
        "data:text/html,",
        "data:text/html;base64,",
        "data:image/svg+xml,",
        "livescript:",
        "javascript://%0a",
        "\u200Bjavascript:",
        "%6A%61%76%61%73%63%72%69%70%74:"
      ])

    map({scheme, payload}, fn {scheme, payload} -> scheme <> payload end)
  end

  @doc "A URL: ordinary, relative, or script-running."
  def url do
    one_of([
      script_url(),
      member_of([
        "https://example.com/",
        "http://example.com/a?b=c&d=e#f",
        "/t/slug/1",
        "//evil.example/x",
        "mailto:a@b.c",
        "#anchor",
        "ftp://example.com",
        "https://example.com/\"onmouseover=\"alert(1)",
        "https://example.com/'><script>alert(1)</script>",
        "https://ex ample.com",
        ""
      ]),
      map(adversarial_text(5), &("https://example.com/" <> &1))
    ])
  end

  @doc "An HTML attribute, dangerous or not."
  def html_attribute do
    one_of([
      map({member_of(@event_attributes), member_of(["alert(1)", "", "x"])}, fn {k, v} ->
        ~s(#{k}="#{v}")
      end),
      map(
        {member_of(~w(href src action formaction xlink:href data poster background
                        srcdoc lowsrc dynsrc)), url()},
        fn {k, v} ->
          Enum.random([~s(#{k}="#{v}"), ~s(#{k}='#{v}'), ~s(#{k}=#{v})])
        end
      ),
      map(member_of(["expression(alert(1))", "background:url(javascript:alert(1))", "x"]), fn v ->
        ~s(style="#{v}")
      end),
      member_of([
        ~s(class="x"),
        ~s(id="main"),
        ~s(title="t"),
        ~s(class="emoji"),
        ~s(data-math-style="inline"),
        ~s(data-math-style="evil"),
        ~s(rel="noopener"),
        ~s(target="_blank"),
        "/",
        ~s(x=">"),
        "\"onerror=\"alert(1)",
        "onerror=alert(1)//"
      ])
    ])
  end

  @doc """
  An HTML fragment: nested, possibly unclosed elements, dangerous ones
  included, with attributes, comments, CDATA and entities.
  """
  def html_fragment(depth \\ 3) do
    tree(html_leaf(), fn child ->
      map(
        {member_of(@dangerous_tags ++ @benign_tags), list_of(html_attribute(), max_length: 3),
         list_of(child, max_length: 3), boolean()},
        fn {tag, attrs, children, close?} ->
          attrs = Enum.map_join(attrs, &(" " <> &1))
          inner = Enum.join(children)
          if close?, do: "<#{tag}#{attrs}>#{inner}</#{tag}>", else: "<#{tag}#{attrs}>#{inner}"
        end
      )
    end)
    |> scale(&min(&1, depth * 10))
  end

  defp html_leaf do
    one_of([
      adversarial_text(4),
      member_of([
        "<script>alert(1)</script>",
        "<SCRIPT SRC=//x.example/x.js></SCRIPT>",
        "<scr<script>ipt>alert(1)</script>",
        "<img src=x onerror=alert(1)>",
        "<svg/onload=alert(1)>",
        "<svg><script>alert(1)</script></svg>",
        "<math><mtext><table><mglyph><style><img src=x onerror=alert(1)>",
        "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
        "<a href=\"javascript:alert(1)\">x</a>",
        "<a href=\"jav&#x09;ascript:alert(1)\">x</a>",
        "<body onload=alert(1)>",
        "<!-- <script>alert(1)</script> -->",
        "<!--><script>alert(1)</script>-->",
        "<![CDATA[<script>alert(1)</script>]]>",
        "<?xml version=\"1.0\"?>",
        "<!DOCTYPE html>",
        "<style>@import 'javascript:alert(1)';</style>",
        "<meta http-equiv=\"refresh\" content=\"0;url=javascript:alert(1)\">",
        "<base href=\"javascript:alert(1)//\">",
        "<link rel=stylesheet href=javascript:alert(1)>",
        "<form action=javascript:alert(1)><button>x</button></form>",
        "<details open ontoggle=alert(1)>",
        "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\">",
        "<template><script>alert(1)</script></template>",
        "<object data=\"javascript:alert(1)\"></object>",
        "<embed src=\"javascript:alert(1)\">",
        "<img src=\"x\" alt=\"\" onerror=\"alert(1)\"/>",
        "<img src=`x`onerror=alert(1)>",
        "<<script>script>alert(1)<</script>/script>",
        "<a href=\"\u0001javascript:alert(1)\">x</a>",
        "&lt;script&gt;",
        "&#60;script&#62;",
        "</div></div></div>",
        "<",
        ">",
        "<a",
        "<img src=\"https://example.com/x.png\" alt=\"ok\">",
        "<a href=\"https://example.com\">ok</a>"
      ])
    ])
  end

  @doc "Markdown with links, images, code, HTML, mentions, hashtags, quotes and the rest."
  def markdown do
    piece =
      frequency([
        {3, adversarial_text(6)},
        {2, html_fragment(2)},
        {2, map({adversarial_text(3), url()}, fn {t, u} -> "[#{t}](#{u})" end)},
        {1, map({adversarial_text(3), url()}, fn {t, u} -> "![#{t}](#{u})" end)},
        {1, map(url(), &"<#{&1}>")},
        {1, map(url(), &"[x][r]\n\n[r]: #{&1}\n")},
        {1, map(adversarial_text(3), &"```\n#{&1}\n```\n")},
        {1, map(adversarial_text(3), &"`#{&1}`")},
        {1, map(username(), &"@#{&1}")},
        {1, map(slug(), &"##{&1}")},
        {1, map(adversarial_text(3), &"> #{&1}\n")},
        {1, map(username(), &"> [@#{&1} said:](/t/x/1#post-2)\n> hi\n")},
        {1, map(adversarial_text(3), &">!#{&1}!<")},
        {1, map(adversarial_text(3), &"$#{&1}$")},
        {1, map(adversarial_text(3), &"$$\n#{&1}\n$$")},
        {1, map(adversarial_text(3), &"a[^#{&1}]\n\n[^#{&1}]: note\n")},
        {1, map(adversarial_text(3), &":#{&1}:")},
        {1, bbcode()},
        {1,
         member_of([
           "\n\n",
           "\n",
           "    indented code\n",
           "| a | b |\n|---|---|\n| <script> | x |\n",
           "- [ ] task\n- [x] done\n",
           "~~strike~~",
           "***\n",
           "# Heading\n",
           "Setext\n===\n",
           "1. one\n2. two\n",
           "<div>\n\n*md in html*\n\n</div>\n",
           "[a](<javascript:alert(1)>)",
           "[a](javascript:alert(1) \"t\")",
           "[a](\\javascript:alert(1))",
           "![a](x \"onerror=alert(1)\")",
           "<javascript:alert(1)>",
           "www.example.com",
           "https://example.com/<script>",
           ":poop: :+1: :not_an_emoji:"
         ])}
      ])

    map(list_of(piece, max_length: 12), &Enum.join/1)
  end

  @doc "BBCode, nested and malformed included."
  def bbcode do
    tree(adversarial_text(4), fn child ->
      map(
        {member_of(~w(b i u s quote code url img spoiler size color list * center email
                      youtube left right hr)),
         one_of([constant(nil), url(), adversarial_text(3), member_of(["\"x\"", "red", "7"])]),
         list_of(child, max_length: 3), boolean()},
        fn {tag, arg, children, close?} ->
          open = if arg, do: "[#{tag}=#{arg}]", else: "[#{tag}]"
          inner = Enum.join(children)
          if close?, do: "#{open}#{inner}[/#{tag}]", else: open <> inner
        end
      )
    end)
    |> scale(&min(&1, 20))
  end

  ## Domain data

  @doc "A username registration accepts: letters, digits, - and _ (3 to 20)."
  def username do
    map(
      {string([?a..?z, ?A..?Z, ?0..?9], length: 1),
       string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], min_length: 2, max_length: 15),
       integer(0..99_999)},
      fn {first, rest, n} -> "#{first}#{rest}#{n}" end
    )
  end

  @doc "A valid email address."
  def email do
    map(
      {string([?a..?z, ?A..?Z, ?0..?9, ?., ?_, ?+, ?-], min_length: 1, max_length: 20),
       member_of(["example.com", "Example.COM", "mail.example.org", "xn--bcher-kva.example"])},
      fn {local, domain} -> "#{String.trim(local, ".")}x@#{domain}" end
    )
  end

  @doc "A password (UTF-8 text, multibyte included) of `min` to `max` characters."
  def password(min \\ 8, max \\ 72) do
    string([?a..?z, ?A..?Z, ?0..?9, ?!..?/, 0xE9, 0x3042, 0x1F525],
      min_length: min,
      max_length: max
    )
  end

  @doc "A slug-like word: lowercase letters, digits and dashes."
  def slug do
    map(string([?a..?z, ?0..?9, ?-], min_length: 1, max_length: 20), fn s ->
      "s" <> String.trim(s, "-")
    end)
  end

  @doc "A title: mostly words, with adversarial text."
  def title do
    frequency([
      {3,
       map(
         list_of(string(:alphanumeric, min_length: 1, max_length: 8),
           min_length: 1,
           max_length: 6
         ),
         &Enum.join(&1, " ")
       )},
      {2, adversarial_text(8)},
      {1, member_of(["🔥🔥", "日本語のタイトル", "!!!", "---", "...", "' OR 1=1 --", "a/b\\c", "Ünïcödé"])}
    ])
  end

  @doc "A tag name the tag rules accept (lowercase letters, digits and -)."
  def tag_name do
    map(string([?a..?z, ?0..?9, ?-], min_length: 1, max_length: 20), &("t" <> &1))
  end

  @doc "A `#rrggbb` color (any case)."
  def hex_color do
    map(list_of(integer(0..255), length: 3), fn rgb ->
      "#" <> Enum.map_join(rgb, &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
    end)
    |> bind(fn color -> member_of([String.downcase(color), String.upcase(color)]) end)
  end

  @doc "A semantic version (`1.2.3`, sometimes with a pre-release)."
  def version do
    map({integer(0..5), integer(0..12), integer(0..30), member_of([nil, "rc.1", "beta"])}, fn
      {a, b, c, nil} -> "#{a}.#{b}.#{c}"
      {a, b, c, pre} -> "#{a}.#{b}.#{c}-#{pre}"
    end)
  end

  @doc "A version requirement (`~> 1.0`, `>= 0.2.0`...)."
  def requirement do
    map({member_of(["~>", ">=", "==", "<", ">"]), integer(0..5), integer(0..12)}, fn {op, a, b} ->
      "#{op} #{a}.#{b}.0"
    end)
  end

  @doc "A plugin or package id (`Firefly.Plugin.Manifest`'s format)."
  def package_id do
    map(string([?a..?z, ?0..?9, ?_, ?-], min_length: 1, max_length: 20), &("p" <> &1))
  end

  @doc """
  A valid manifest for a theme-only package (`firefly.json`), with its
  files: `{manifest, files}`.
  """
  def theme_package do
    map(
      {package_id(), version(), string(:alphanumeric, min_length: 1, max_length: 20),
       list_of(
         {member_of(["light", "dark"]), member_of(Firefly.Themes.Palette.tokens()), hex_color()},
         max_length: 4
       ), boolean()},
      fn {id, version, name, colors, css?} ->
        colors =
          Enum.reduce(colors, %{}, fn {scheme, token, color}, acc ->
            Map.update(acc, scheme, %{token => color}, &Map.put(&1, token, color))
          end)

        theme =
          %{"name" => "Theme " <> name, "colors" => colors}
          |> then(&if(css?, do: Map.put(&1, "css", "theme.css"), else: &1))

        manifest = %{
          "id" => id,
          "name" => "Package " <> name,
          "version" => version,
          "firefly" => "~> 1.0",
          "tags" => ["theme"],
          "theme" => theme
        }

        files = if css?, do: %{"theme.css" => "body { color: red; }\n"}, else: %{}
        {manifest, files}
      end
    )
  end

  @doc """
  A JSON value of any shape (for mutating manifests): scalars, odd
  strings, nested lists and objects.
  """
  def json_value do
    tree(
      one_of([
        constant(nil),
        boolean(),
        integer(),
        float(),
        adversarial_text(4),
        member_of(@numbers)
      ]),
      # Objects from key/value pairs, a repeated key keeping its last value:
      # map_of/3 needs distinct keys, and small odd strings are mostly "",
      # so it gave up (TooManyDuplicatesError) on some seeds.
      fn child ->
        one_of([
          list_of(child, max_length: 4),
          map(list_of(tuple({adversarial_text(3), child}), max_length: 4), &Map.new/1)
        ])
      end
    )
    |> scale(&min(&1, 12))
  end
end
