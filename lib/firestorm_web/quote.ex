defmodule FirestormWeb.Quote do
  @moduledoc """
  Markdown quotes of posts, for "Quote" replies:

      > [@alice said:](/categories/1/threads/2#post-3)
      >
      > the quoted text

  The attribution line is rendered as a quote header (see
  `FirestormWeb.Markdown`). A quote can be limited to text the user selected
  in the post, but only if that text really is in the post: otherwise anyone
  could put words in someone else's mouth through the URL.
  """

  alias FirestormWeb.Markdown

  # Longer selections are quoted in full rather than checked. Measured in
  # UTF-8 bytes, like the check in the QuoteSelection JS hook.
  @max_selection 5_000

  @doc """
  The quote markdown for `body` by `username`, linking to `url`. Quotes only
  `selection` when it occurs in the post (its markdown source or its rendered
  text), otherwise the whole body. A selection taken from the rendered text
  that would render differently as markdown (literal `a*b*c` from a code
  span, say) is escaped so it reads as selected.
  """
  @spec build(String.t(), String.t(), String.t(), String.t() | nil) :: String.t()
  def build(body, username, url, selection \\ nil) do
    text =
      cond do
        not in_post?(body, selection) -> String.trim(body)
        literal_in_rendered?(body, selection) -> selection |> String.trim() |> escape()
        true -> String.trim(selection)
      end

    quoted =
      text |> String.split(~r/\R/) |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

    "> [@#{username} said:](#{url})\n>\n#{quoted}\n\n"
  end

  @doc "Whether `selection` is a non-empty part of the post with `body`."
  @spec in_post?(String.t(), String.t() | nil) :: boolean
  def in_post?(body, selection)
      when is_binary(selection) and byte_size(selection) <= @max_selection do
    needle = normalize(selection)

    needle != "" and
      (String.contains?(normalize(body), needle) or
         String.contains?(normalize(rendered_text(body)), needle))
  end

  def in_post?(_body, _selection), do: false

  defp literal_in_rendered?(body, selection) do
    needle = normalize(selection)

    String.contains?(normalize(rendered_text(body)), needle) and
      normalize(rendered_text(selection)) != needle
  end

  # Backslash-escapes Markdown and HTML metacharacters (CommonMark allows a
  # backslash before any ASCII punctuation).
  defp escape(text), do: String.replace(text, ~r/[\\`*_{}\[\]()<>#+\-!|~&]/, "\\\\\\0")

  # What the reader sees (and selects): the rendered post without markup.
  defp rendered_text(body) do
    body
    |> Markdown.render()
    |> HtmlSanitizeEx.strip_tags()
    |> unescape()
  end

  defp unescape(text) do
    Enum.reduce(
      [{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&#39;", "'"}, {"&amp;", "&"}],
      text,
      fn {entity, char}, acc -> String.replace(acc, entity, char) end
    )
  end

  defp normalize(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
