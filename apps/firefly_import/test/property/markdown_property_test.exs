defmodule FireflyImport.MarkdownPropertyTest do
  @moduledoc """
  Properties of the importers' conversions (`FireflyImport.Markdown`): HTML
  and BBCode from other forums convert without crashing, whatever they
  hold, and what they convert to renders safely.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators

  alias Firefly.HTMLSafety
  alias Firefly.Rendering.Markdown, as: Renderer
  alias FireflyImport.Markdown

  defp bbcode_style?(style),
    do: style =~ ~r/\A(color: (#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|[a-z]+)|font-size: [0-9]{2,3}%)\z/

  defp assert_imports_safely(input) do
    for markdown <- [Markdown.from_html(input), Markdown.from_bbcode(input)] do
      assert is_binary(markdown)
      html = Renderer.render(markdown)

      assert HTMLSafety.unsafe(html, allow_style: &bbcode_style?/1) == [],
             "unsafe import of #{inspect(input)}:\n#{html}"
    end
  end

  property "HTML and BBCode convert, and render safely" do
    check all(input <- one_of([html_fragment(), bbcode(), markdown()]), max_runs: runs(100)) do
      assert_imports_safely(input)
    end
  end

  property "conversions are total on any text" do
    check all(input <- any_text(), max_runs: runs(100)) do
      assert is_binary(Markdown.from_html(input))
      assert is_binary(Markdown.from_bbcode(input))
      assert is_binary(Markdown.decode_entities(input))
    end
  end

  property "plain words come through as they are" do
    check all(
            words <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 10),
                min_length: 1,
                max_length: 8
              ),
            max_runs: runs(100)
          ) do
      text = Enum.join(words, " ")
      assert String.trim(Markdown.from_html("<p>#{text}</p>")) == text
      assert Markdown.from_bbcode(text) == text
    end
  end

  property "decoded entities are the characters they name" do
    check all(text <- string(:printable, max_length: 30), max_runs: runs(100)) do
      encoded =
        String.replace(text, ["&", "<", ">", "\"", "'"], fn
          "&" -> "&amp;"
          "<" -> "&lt;"
          ">" -> "&gt;"
          "\"" -> "&quot;"
          "'" -> "&#39;"
        end)

      assert Markdown.decode_entities(encoded) == text
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "imports stay total and safe" do
      check all(
              input <- one_of([html_fragment(4), bbcode(), markdown(), any_text()]),
              max_runs: fuzz_runs()
            ) do
        assert_imports_safely(input)
      end
    end
  end
end
