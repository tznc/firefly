defmodule FirestormWeb.LinkPreviews.Parser do
  @moduledoc """
  Reads a page's preview from its `<head>`: OpenGraph (`og:title`,
  `og:description`, `og:site_name`, `og:image`), else Twitter card tags,
  else `<title>` and `<meta name="description">`. Values come back as
  plain text (entities decoded, tags and control characters removed,
  whitespace collapsed, length capped); they're escaped when shown. The
  image is an absolute http(s) URL, or nil.
  """

  # Only the head matters, and pages can be big.
  @scan_bytes 512 * 1024
  @limits %{title: 200, description: 300, site_name: 100}

  @doc "The preview fields of `html`, fetched from `base_url`."
  def parse(html, base_url) do
    head = html |> binary_part(0, min(byte_size(html), @scan_bytes)) |> head()
    meta = meta(head)

    %{
      title: first(meta, ~w(og:title twitter:title)) || title(head),
      description: first(meta, ~w(og:description twitter:description description)),
      site_name: first(meta, ~w(og:site_name application-name)),
      image:
        image(
          first(
            meta,
            ~w(og:image og:image:url og:image:secure_url twitter:image twitter:image:src)
          ),
          base_url
        )
    }
    |> Map.new(fn
      {:image, url} -> {:image, url}
      {key, value} -> {key, clean(value, @limits[key])}
    end)
  end

  defp head(html) do
    case :binary.match(String.downcase(html), "</head") do
      {at, _} -> binary_part(html, 0, at)
      :nomatch -> html
    end
  end

  # `property`/`name` => `content`, the first of each.
  defp meta(head) do
    ~r/<meta\s(?:[^>"']|"[^"]*"|'[^']*')*>/i
    |> Regex.scan(head)
    |> Enum.map(fn [tag] -> attributes(tag) end)
    |> Enum.reduce(%{}, fn attrs, acc ->
      key = attrs["property"] || attrs["name"]

      if is_binary(key) and is_binary(attrs["content"]),
        do: Map.put_new(acc, String.downcase(key), attrs["content"]),
        else: acc
    end)
  end

  defp attributes(tag) do
    for [_, name | value] <-
          Regex.scan(~r/([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/, tag),
        into: %{},
        do: {String.downcase(name), Enum.find(value, "", &(&1 != ""))}
  end

  defp first(meta, keys), do: Enum.find_value(keys, &present(meta[&1]))

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  defp title(head) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, head) do
      [_, title] -> present(title)
      nil -> nil
    end
  end

  defp image(nil, _base_url), do: nil

  defp image(url, base_url) do
    uri = base_url |> URI.merge(decode(String.trim(url))) |> URI.to_string()
    if String.starts_with?(uri, ["https://", "http://"]), do: uri, else: nil
  rescue
    _invalid -> nil
  end

  defp clean(nil, _limit), do: nil

  defp clean(text, limit) do
    text
    |> decode()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, limit)
    |> present()
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  defp decode(text) do
    text = if String.valid?(text), do: text, else: :unicode.characters_to_binary(text, :latin1)

    Regex.replace(~r/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/, text, fn whole, entity ->
      case entity do
        "#x" <> hex -> codepoint(String.to_integer(hex, 16), whole)
        "#" <> decimal -> codepoint(String.to_integer(decimal), whole)
        name -> Map.get(@entities, String.downcase(name), whole)
      end
    end)
  end

  defp codepoint(n, _whole) when n in 0x20..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp codepoint(_n, whole), do: whole
end
