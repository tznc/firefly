defmodule FireflyImport.Markdown do
  @moduledoc """
  Converting other platforms' post formats to Markdown, what Firefly posts
  are written in:

    * `from_html/1`: HTML (paragraphs, emphasis, links, images, lists,
      quotes, code, headings, tables)
    * `from_bbcode/1`: BBCode, with Firefly's own converter (see
      `Firefly.Rendering.BBCode`), so imported posts don't depend on the
      `bbcode` setting
  """

  alias Firefly.Rendering.BBCode

  @doc "`text` with its BBCode converted to Markdown."
  def from_bbcode(nil), do: ""
  def from_bbcode(text), do: BBCode.to_markdown(text)

  @doc "`html` as Markdown."
  def from_html(nil), do: ""

  def from_html(html) do
    case Floki.parse_fragment(html) do
      {:ok, nodes} -> nodes |> blocks() |> tidy()
      {:error, _reason} -> html
    end
  end

  defp tidy(markdown) do
    markdown
    |> String.replace(~r/[ \t]+\n/, fn match -> if match =~ ~r/^  \n$/, do: match, else: "\n" end)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp blocks(nodes), do: Enum.map_join(nodes, &html_node/1)

  defp html_node(text) when is_binary(text), do: text |> String.replace(~r/\s+/, " ") |> escape()
  defp html_node({:comment, _}), do: ""

  defp html_node({tag, _attrs, children}) when tag in ~w(p div section article),
    do: "\n\n" <> String.trim(blocks(children)) <> "\n\n"

  defp html_node({"br", _, _}), do: "  \n"
  defp html_node({"hr", _, _}), do: "\n\n---\n\n"

  defp html_node({"h" <> level, _, children}) when level in ~w(1 2 3 4 5 6),
    do:
      "\n\n#{String.duplicate("#", String.to_integer(level))} #{String.trim(blocks(children))}\n\n"

  defp html_node({tag, _, children}) when tag in ~w(strong b), do: wrap("**", children)
  defp html_node({tag, _, children}) when tag in ~w(em i), do: wrap("*", children)
  defp html_node({tag, _, children}) when tag in ~w(del s strike), do: wrap("~~", children)

  defp html_node({"code", _, children}) do
    code = Floki.text(children)
    fence = if String.contains?(code, "`"), do: "``", else: "`"
    "#{fence}#{code}#{fence}"
  end

  defp html_node({"pre", _, children}) do
    language =
      case Floki.attribute(children, "code", "class") do
        [class | _] -> class |> String.split() |> Enum.find_value("", &language/1)
        [] -> ""
      end

    "\n\n```#{language}\n#{String.trim_trailing(Floki.text(children))}\n```\n\n"
  end

  defp html_node({"a", attrs, children}) do
    text = children |> blocks() |> String.trim()

    case attr(attrs, "href") do
      nil -> text
      href when text in ["", href] -> "<#{href}>"
      href -> "[#{text}](#{href})"
    end
  end

  defp html_node({"img", attrs, _}) do
    case attr(attrs, "src") do
      nil -> ""
      src -> "![#{attr(attrs, "alt") || ""}](#{src})"
    end
  end

  defp html_node({"blockquote", _, children}) do
    quoted =
      children
      |> blocks()
      |> tidy()
      |> String.split("\n")
      |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))

    "\n\n" <> quoted <> "\n\n"
  end

  defp html_node({tag, _, children}) when tag in ~w(ul ol),
    do: "\n\n" <> list(tag, children) <> "\n\n"

  defp html_node({"table", _, children}), do: "\n\n" <> table(children) <> "\n\n"

  defp html_node({tag, _, _}) when tag in ~w(script style head), do: ""
  defp html_node({_tag, _, children}), do: blocks(children)
  defp html_node(_other), do: ""

  defp wrap(mark, children) do
    case children |> blocks() |> String.trim() do
      "" -> ""
      text -> mark <> text <> mark
    end
  end

  defp language("lang-" <> language), do: language
  defp language("language-" <> language), do: language
  defp language(_class), do: nil

  defp list(tag, children) do
    children
    |> Enum.filter(&match?({"li", _, _}, &1))
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{"li", _, item}, n} ->
      marker = if tag == "ol", do: "#{n}. ", else: "- "
      indent = String.duplicate(" ", String.length(marker))

      # Tight: an item's paragraphs and nested lists on lines of their own.
      [first | rest] =
        item |> blocks() |> tidy() |> String.replace(~r/\n{2,}/, "\n") |> String.split("\n")

      Enum.join([marker <> first | Enum.map(rest, &indent_line(&1, indent))], "\n")
    end)
  end

  defp indent_line("", _indent), do: ""
  defp indent_line(line, indent), do: indent <> line

  defp table(children) do
    rows =
      for {"tr", _, cells} <- Floki.find(children, "tr") do
        for {tag, _, content} <- cells, tag in ~w(th td) do
          content
          |> blocks()
          |> tidy()
          |> String.replace(~r/\s*\n\s*/, " ")
          |> String.replace("|", "\\|")
        end
      end

    case rows do
      [] ->
        ""

      [header | body] ->
        separator = Enum.map(header, fn _ -> "---" end)
        Enum.map_join([header, separator | body], "\n", &("| " <> Enum.join(&1, " | ") <> " |"))
    end
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  # Text that would otherwise read as Markdown.
  defp escape(text), do: String.replace(text, ~r/([\\`*_\[\]<>])/, "\\\\\\1")
end
