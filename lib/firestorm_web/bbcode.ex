defmodule FirestormWeb.BBCode do
  @moduledoc """
  BBCode, converted to Markdown (and the inline HTML Markdown would
  produce) before a post is rendered, so it goes through the same parser
  and sanitizer as everything else (see `FirestormWeb.Markdown`):

    * `[b]`, `[i]`, `[u]`, `[s]`: `<strong>`, `<em>`, `<u>`, `<del>`
    * `[quote]`, `[quote=user]`: a blockquote, the latter starting
      "@user said:" (only a valid username is used)
    * `[code]`: a fenced code block, or a code span when it's one line;
      nothing inside is converted
    * `[url]https://...[/url]`, `[url=https://...]text[/url]`: a link;
      `[img]https://...[/img]`: an image. Only http(s) and mailto links and
      http(s) or site-relative images; anything else stays as written
    * `[list]`, `[list=1]` with `[*]` items: bulleted or numbered lists,
      nested too
    * `[color=...]`: a named CSS color or `#rgb`/`#rrggbb` only;
      `[size=...]`: 1 to 7, or a percentage from 50 to 200. Other values
      keep the text without the formatting
    * `[spoiler]`: a spoiler (see `FirestormWeb.Markdown`), a block when it
      spans paragraphs

  Tags are matched case-insensitively; unmatched or unknown ones, and
  those named in `skip` (plugins' shortcodes), are left as text. Markdown code (fenced and indented blocks, code spans) is never
  touched.
  """

  @tags ~w(b i u s quote url img list color size spoiler)
  @inline %{"b" => "strong", "i" => "em", "u" => "u", "s" => "del"}
  @colors ~w(black white gray grey silver red maroon orange yellow olive lime green teal
             aqua cyan blue navy purple fuchsia magenta pink brown gold indigo violet)
  @username ~r/\A[A-Za-z0-9_-]{1,32}\z/
  # Private-use characters around the index of a protected (code) piece.
  @open_mark ""
  @close_mark ""

  @doc "`text` with its BBCode converted to Markdown."
  @spec to_markdown(String.t(), [String.t()]) :: String.t()
  def to_markdown(text, skip \\ []) when is_binary(text) do
    if String.contains?(text, "[") and not String.contains?(text, [@open_mark, @close_mark]),
      do: convert(text, Enum.map(skip, &String.downcase/1)),
      else: text
  end

  defp convert(text, skip) do
    {text, protected} = protect_code(text)

    {text, protected} =
      if "code" in skip, do: {text, protected}, else: bbcode_code(text, protected)

    text
    |> tokenize(@tags -- skip)
    |> parse([])
    |> Enum.map_join(&render/1)
    |> restore(protected)
  end

  ## Code, kept as it is

  # Markdown code (fenced and indented blocks, then code spans) is swapped
  # for numbered marks, put back at the end.
  defp protect_code(text) do
    {lines, protected} = code_blocks(String.split(text, "\n"), :text, true, [], [], [])
    protect_spans(Enum.join(lines, "\n"), protected)
  end

  # Lines of fenced code blocks (one left open runs to the end), and of
  # indented code after a blank line, each block replaced by one mark.
  defp code_blocks([], _state, _after_blank, block, out, protected) do
    {out, protected} = flush(block, out, protected)
    {Enum.reverse(out), protected}
  end

  defp code_blocks([line | rest], :text, after_blank, [], out, protected) do
    cond do
      fence = Regex.run(~r/\A {0,3}(`{3,}|~{3,})/, line) ->
        code_blocks(rest, {:fence, Enum.at(fence, 1)}, false, [line], out, protected)

      after_blank and indented?(line) ->
        code_blocks(rest, :indented, false, [line], out, protected)

      true ->
        code_blocks(rest, :text, String.trim(line) == "", [], [line | out], protected)
    end
  end

  defp code_blocks([line | rest], {:fence, fence} = state, _, block, out, protected) do
    if Regex.match?(~r/\A {0,3}#{Regex.escape(fence)}[`~]*\s*\z/, line) do
      {out, protected} = flush([line | block], out, protected)
      code_blocks(rest, :text, false, [], out, protected)
    else
      code_blocks(rest, state, false, [line | block], out, protected)
    end
  end

  defp code_blocks([line | rest] = lines, :indented, _, block, out, protected) do
    if indented?(line) or String.trim(line) == "" do
      code_blocks(rest, :indented, false, [line | block], out, protected)
    else
      {out, protected} = flush(block, out, protected)
      code_blocks(lines, :text, false, [], out, protected)
    end
  end

  defp indented?(line), do: Regex.match?(~r/\A(?: {4}|\t)/, line)

  defp flush([], out, protected), do: {out, protected}

  defp flush(block, out, protected),
    do:
      {[placeholder(length(protected)) | out],
       protected ++ [Enum.join(Enum.reverse(block), "\n")]}

  @span ~r/(?<!`)(`+)(?!`).+?(?<!`)\1(?!`)/s
  @whole_span ~r/\A(`+)(?!`).+?(?<!`)\1\z/s

  defp protect_spans(text, protected) do
    @span
    |> Regex.split(text, include_captures: true)
    |> Enum.reduce({"", protected}, fn piece, {acc, protected} ->
      if Regex.match?(@whole_span, piece),
        do: {acc <> placeholder(length(protected)), protected ++ [piece]},
        else: {acc <> piece, protected}
    end)
  end

  defp placeholder(index), do: @open_mark <> Integer.to_string(index) <> @close_mark

  defp restore(text, protected) do
    Regex.replace(~r/#{@open_mark}(\d+)#{@close_mark}/u, text, fn _, index ->
      Enum.at(protected, String.to_integer(index))
    end)
  end

  # [code]...[/code]: its content is code, so it's turned into a protected
  # Markdown code block or span first.
  defp bbcode_code(text, protected) do
    ~r/\[code\](.*?)\[\/code\]/is
    |> Regex.split(text, include_captures: true)
    |> Enum.reduce({"", protected}, fn piece, {acc, protected} ->
      case Regex.run(~r/\A\[code\](.*)\[\/code\]\z/is, piece) do
        [_, code] ->
          {acc <> placeholder(length(protected)),
           protected ++ [code_markdown(restore(code, protected))]}

        nil ->
          {acc <> piece, protected}
      end
    end)
  end

  defp code_markdown(code) do
    if String.contains?(code, "\n") do
      code = code |> String.trim_leading("\n") |> String.trim_trailing()
      fence = String.duplicate("`", max(3, longest_run(code, "`") + 1))
      "\n\n#{fence}\n#{code}\n#{fence}\n\n"
    else
      ticks = String.duplicate("`", longest_run(code, "`") + 1)
      "#{ticks} #{code} #{ticks}"
    end
  end

  defp longest_run(text, char) do
    ~r/#{Regex.escape(char)}+/
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  ## Tags

  @tag ~r/\[(\/?)(b|i|u|s|quote|url|img|list|color|size|spoiler)(?:=([^\]\n]{1,200}))?\]|\[\*\]/i

  defp tokenize(text, tags) do
    @tag
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn piece -> token(piece, Regex.run(@tag, piece), tags) end)
  end

  defp token(piece, [piece], tags),
    do: if("list" in tags, do: {:item, piece}, else: {:text, piece})

  defp token(piece, [piece, slash, name | arg], tags) do
    name = String.downcase(name)

    cond do
      name not in tags -> {:text, piece}
      slash == "/" -> {:close, name, piece}
      true -> {:open, name, unquote_arg(arg), piece}
    end
  end

  defp token(piece, _no_tag, _tags), do: {:text, piece}

  defp unquote_arg([arg]), do: arg |> String.trim() |> String.trim("\"") |> String.trim("'")
  defp unquote_arg(_none), do: nil

  # Builds the tag tree: `{:tag, name, arg, raw, children}`, text and
  # `:item` marks. A closing tag closes the nearest open one of its name
  # (those opened inside it and never closed stay as text).
  defp parse([], stack), do: unwind(stack)

  defp parse([{:open, name, arg, raw} | rest], stack),
    do: parse(rest, [{name, arg, raw, []} | stack])

  defp parse([{:close, name, raw} | rest], stack) do
    if Enum.any?(stack, &(elem(&1, 0) == name)),
      do: parse(rest, close(name, stack)),
      else: parse(rest, add(stack, {:text, raw}))
  end

  defp parse([token | rest], stack), do: parse(rest, add(stack, token))

  defp add([], node), do: [{:root, nil, "", [node]}]

  defp add([{name, arg, raw, children} | stack], node),
    do: [{name, arg, raw, [node | children]} | stack]

  defp close(name, [{name, arg, raw, children} | stack]),
    do: add(stack, {:tag, name, arg, raw, Enum.reverse(children)})

  defp close(name, [{_other, _arg, raw, children} | stack]),
    do: close(name, add_all(stack, [{:text, raw} | Enum.reverse(children)]))

  defp add_all(stack, nodes), do: Enum.reduce(nodes, stack, &add(&2, &1))

  # Whatever is still open at the end is text.
  defp unwind([{:root, nil, "", children}]), do: Enum.reverse(children)
  defp unwind([]), do: []

  defp unwind([{_name, _arg, raw, children} | stack]),
    do: unwind(add_all(stack, [{:text, raw} | Enum.reverse(children)]))

  ## Rendering

  defp render({:text, text}), do: text
  defp render({:item, raw}), do: raw

  defp render({:tag, name, _arg, _raw, children}) when is_map_key(@inline, name),
    do: "<#{@inline[name]}>#{render_all(children)}</#{@inline[name]}>"

  defp render({:tag, "quote", arg, _raw, children}) do
    attribution = if is_binary(arg) and arg =~ @username, do: "@#{arg} said:\n\n", else: ""
    "\n\n<blockquote>\n\n#{attribution}#{String.trim(render_all(children))}\n\n</blockquote>\n\n"
  end

  defp render({:tag, "url", nil, raw, children} = node) do
    url = children |> render_all() |> String.trim()
    if link?(url), do: "<#{url}>", else: as_text(node, raw)
  end

  defp render({:tag, "url", url, raw, children} = node) do
    if link?(url), do: "[#{render_all(children)}](<#{url}>)", else: as_text(node, raw)
  end

  defp render({:tag, "img", _arg, raw, children} = node) do
    url = children |> render_all() |> String.trim()

    if image?(url), do: "![](<#{url}>)", else: as_text(node, raw)
  end

  defp render({:tag, "color", color, _raw, children}) do
    case color(color) do
      nil -> render_all(children)
      color -> ~s(<span style="color: #{color}">#{render_all(children)}</span>)
    end
  end

  defp render({:tag, "size", size, _raw, children}) do
    case size(size) do
      nil -> render_all(children)
      percent -> ~s(<span style="font-size: #{percent}%">#{render_all(children)}</span>)
    end
  end

  defp render({:tag, "spoiler", _arg, _raw, children}) do
    content = render_all(children)

    if String.contains?(String.trim(content), "\n\n"),
      do: ~s(\n\n<div class="spoiler">\n\n#{String.trim(content)}\n\n</div>\n\n),
      else: ~s(<span class="spoiler">#{content}</span>)
  end

  defp render({:tag, "list", arg, _raw, children}) do
    marker = if arg in ["1", "a", "A", "i", "I"], do: "1. ", else: "- "
    indent = String.duplicate(" ", String.length(marker))

    items =
      children
      |> Enum.chunk_by(&match?({:item, _}, &1))
      |> Enum.reject(&match?([{:item, _} | _], &1))
      # Blank lines would make a loose list (and end a nested one).
      |> Enum.map(&(&1 |> render_all() |> String.trim() |> String.replace(~r/\n\s*\n/, "\n")))
      |> Enum.reject(&(&1 == ""))

    lines =
      Enum.map_join(items, "\n", fn item ->
        marker <> String.replace(item, "\n", "\n" <> indent)
      end)

    "\n\n#{lines}\n\n"
  end

  defp render_all(nodes), do: Enum.map_join(nodes, &render/1)

  defp as_text({:tag, name, _arg, raw, children}, raw),
    do: raw <> render_all(children) <> "[/#{name}]"

  defp link?(url) do
    not String.contains?(url, [" ", "<", ">", "\n"]) and
      String.starts_with?(String.downcase(url), ["https://", "http://", "mailto:"])
  end

  defp image?(url) do
    not String.contains?(url, [" ", "<", ">", "\n"]) and
      (String.starts_with?(String.downcase(url), ["https://", "http://"]) or
         (String.starts_with?(url, "/") and not String.starts_with?(url, "//")))
  end

  defp color(nil), do: nil

  defp color(color) do
    color = String.downcase(color)

    cond do
      color in @colors -> color
      color =~ ~r/\A#(?:[0-9a-f]{3}|[0-9a-f]{6})\z/ -> color
      true -> nil
    end
  end

  # 1-7 are the classic size steps; larger numbers are percentages.
  @steps %{1 => 70, 2 => 85, 3 => 100, 4 => 120, 5 => 150, 6 => 175, 7 => 200}

  defp size(nil), do: nil

  defp size(size) do
    case Integer.parse(String.trim_trailing(size, "%")) do
      {n, ""} when n in 1..7 -> @steps[n]
      {n, ""} when n in 50..200 -> n
      _invalid -> nil
    end
  end
end
