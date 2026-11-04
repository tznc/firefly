defmodule Firefly.HTMLSafety do
  @moduledoc """
  What property tests check sanitized HTML for (`unsafe/1`): no element
  that runs scripts or loads a document, no event-handler or inline-style
  attribute, and no URL that runs script (`javascript:`, `vbscript:`,
  `data:` documents), however it is spelled.
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @forbidden_tags ~w(script style iframe frame frameset object embed applet form input
                     button textarea select base meta link svg math template noscript
                     portal dialog)
  @url_attributes ~w(href src action formaction xlink:href data poster background lowsrc
                     dynsrc srcset cite longdesc usemap)

  @doc """
  The problems in `html` as a list of strings (empty when it's safe).
  `opts`: `allow_tags` (tags the caller does allow, such as `meta` and
  `link` in a theme's head), `allow_style` (inline styles allowed).
  """
  def unsafe(html, opts \\ []) when is_binary(html) do
    allowed = Keyword.get(opts, :allow_tags, [])

    raw =
      for pattern <- [~r/<\s*script/i, ~r/<\s*iframe/i, ~r/<\s*object/i, ~r/<\s*embed/i],
          Regex.match?(pattern, html),
          do: "raw #{inspect(pattern.source)}"

    raw ++ walk(parse(html), allowed, opts)
  end

  defp parse(html) do
    case :mochiweb_html.parse("<firefly-root>" <> html <> "</firefly-root>") do
      {_tag, _attrs, children} -> children
      _ -> []
    end
  rescue
    # mochiweb gives up on some malformed input: then only the raw checks apply.
    _ -> []
  end

  defp walk(nodes, allowed, opts) when is_list(nodes),
    do: Enum.flat_map(nodes, &walk(&1, allowed, opts))

  defp walk({tag, attrs, children}, allowed, opts) when is_binary(tag) do
    tag = String.downcase(tag)

    tag_problems =
      if tag in @forbidden_tags and tag not in allowed, do: ["<#{tag}> element"], else: []

    attr_problems = Enum.flat_map(attrs, &attribute(tag, &1, opts))
    tag_problems ++ attr_problems ++ walk(children, allowed, opts)
  end

  defp walk(_text_or_comment, _allowed, _opts), do: []

  defp attribute(tag, {name, value}, opts) do
    name = String.downcase(name)

    cond do
      String.starts_with?(name, "on") ->
        ["#{name} handler on <#{tag}>"]

      name == "style" and not Keyword.get(opts, :allow_style, false) ->
        ["style attribute on <#{tag}>"]

      name == "srcdoc" ->
        ["srcdoc on <#{tag}>"]

      name in @url_attributes and script_url?(value) ->
        ["#{name}=#{inspect(value)} on <#{tag}>"]

      true ->
        []
    end
  end

  @doc "Whether `url` (an attribute value, entities decoded) runs script when followed."
  def script_url?(url) do
    normalized =
      url
      |> decode_entities()
      |> String.replace(~r/[\x00-\x20\x7F\x{200B}-\x{200D}\x{FEFF}]/u, "")
      |> String.downcase()

    String.starts_with?(normalized, [
      "javascript:",
      "vbscript:",
      "livescript:",
      "data:text/html",
      "data:image/svg"
    ])
  end

  defp decode_entities(text) do
    text
    |> then(
      &Regex.replace(~r/&#x0*([0-9a-f]+);?/i, &1, fn _, hex ->
        codepoint(String.to_integer(hex, 16))
      end)
    )
    |> then(
      &Regex.replace(~r/&#0*([0-9]+);?/, &1, fn _, dec -> codepoint(String.to_integer(dec)) end)
    )
    |> String.replace(["&colon;", "&Tab;", "&NewLine;"], fn
      "&colon;" -> ":"
      "&Tab;" -> "\t"
      "&NewLine;" -> "\n"
    end)
  end

  defp codepoint(n) when n in 0..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp codepoint(_n), do: ""
end
