defmodule Firefly.ThemesPropertyTest do
  @moduledoc """
  Properties of `Firefly.Themes`: a theme's HTML is cleaned of anything
  that runs script unless an admin allowed scripts; its stylesheet can't
  be broken out of by what admins or packages name things; edits never
  crash validation; and contrast checks are symmetric and bounded.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.HTMLSafety
  alias Firefly.Themes
  alias Firefly.Themes.{Contrast, Palette, Theme}

  defp html(place_html, scripts? \\ false) do
    theme = %Theme{
      name: "T",
      head_html: place_html,
      header_html: place_html,
      footer_html: place_html,
      allow_scripts: scripts?,
      components: []
    }

    for place <- [:head, :header, :footer], do: Themes.html(theme, place, "n0nce")
  end

  defp assert_clean(input) do
    for out <- html(input) do
      # A theme's head may link stylesheets and set meta tags.
      assert HTMLSafety.unsafe(out, allow_tags: ["meta", "link"]) == [],
             "unsafe theme HTML for #{inspect(input)}:\n#{out}"
    end
  end

  describe "html/3 without scripts" do
    property "never lets scripts, handlers or script URLs through" do
      check all(input <- one_of([html_fragment(), markdown()]), max_runs: runs(150)) do
        assert_clean(input)
      end
    end

    property "is total" do
      check all(input <- any_text(), max_runs: runs(100)) do
        assert Enum.all?(html(input), &is_binary/1)
      end
    end
  end

  describe "html/3 with scripts allowed" do
    property "every script carries the nonce" do
      check all(input <- html_fragment(), max_runs: runs(100)) do
        for out <- html(input, true),
            [tag] <- Regex.scan(~r/<script\b[^>]*>/i, out) do
          assert tag =~ "nonce=", "a script without the nonce: #{tag}"
        end
      end
    end
  end

  describe "the stylesheet" do
    property "the theme's name stays inside its comment" do
      check all(
              name <-
                one_of([adversarial_text(10), member_of(["*/", "**//", "*/*/", "/**/", "* /"])]),
              max_runs: runs(100)
            ) do
        css = Themes.compile(%Theme{name: name, version: 1, components: [], assets: [], css: ""})
        assert String.starts_with?(css, "/* ")
        # The comment's first end is the one compile/1 writes, after the
        # version (a name may hold newlines: they're inside the comment).
        [header | _] = String.split(css, "*/", parts: 2)
        assert String.ends_with?(header, " v1 "), "the name closed the comment: #{inspect(css)}"
      end
    end

    property "colors compile to one declaration each" do
      check all(colors <- color_map(), max_runs: runs(100)) do
        css = Themes.color_css(%Theme{colors: colors, components: []})

        for {scheme, tokens} <- colors, {token, value} <- tokens do
          assert css =~ "[data-theme=#{Palette.data_theme(scheme)}] {"
          assert css =~ "--color-#{token}: #{value};"
        end

        assert css |> String.graphemes() |> Enum.count(&(&1 == "{")) ==
                 css |> String.graphemes() |> Enum.count(&(&1 == "}"))
      end
    end
  end

  describe "changeset/2" do
    property "never raises, and accepted colors are known tokens with #rrggbb values" do
      check all(
              colors <-
                one_of([
                  color_map(),
                  json_value(),
                  optional_map(%{
                    "light" => json_value(),
                    "dark" => json_value(),
                    "x" => json_value()
                  })
                ]),
              css <- one_of([adversarial_text(), constant("a { color: red }")]),
              name <- title(),
              max_runs: runs(150)
            ) do
        changeset = Theme.changeset(%Theme{}, %{"name" => name, "colors" => colors, "css" => css})

        if changeset.valid? do
          for {scheme, tokens} <- Ecto.Changeset.get_field(changeset, :colors) || %{},
              {token, value} <- tokens do
            assert scheme in Palette.schemes()
            assert token in Palette.tokens()
            assert value =~ ~r/\A#[0-9a-f]{6}\z/
          end
        end
      end
    end

    property "accepted CSS has balanced braces outside comments and strings" do
      check all(
              css <-
                list_of(member_of(["a", "{", "}", "/*", "*/", "\"", "'", "\\", " ", "\n", ";"]),
                  max_length: 30
                ),
              max_runs: runs(200)
            ) do
        css = Enum.join(css)
        changeset = Theme.changeset(%Theme{}, %{"name" => "T", "css" => css})

        if changeset.valid? do
          stripped = Regex.replace(~r{/\*.*?\*/|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'}s, css, "")

          assert Enum.reduce_while(String.graphemes(stripped), 0, fn
                   "{", n -> {:cont, n + 1}
                   "}", 0 -> {:halt, -1}
                   "}", n -> {:cont, n - 1}
                   _, n -> {:cont, n}
                 end) == 0
        end
      end
    end
  end

  describe "contrast" do
    property "is symmetric, bounded by 1 and 21, and 1 for a color against itself" do
      check all(a <- hex_color(), b <- hex_color(), max_runs: runs(200)) do
        ratio = Contrast.ratio(a, b)
        assert_in_delta ratio, Contrast.ratio(b, a), 1.0e-12
        assert ratio >= 1.0 and ratio <= 21.0 + 1.0e-9
        assert_in_delta Contrast.ratio(a, a), 1.0, 1.0e-12
        assert_in_delta Contrast.ratio(a, String.upcase(a)), 1.0, 1.0e-12
      end
    end

    property "warnings are exactly the pairs below AA" do
      check all(colors <- color_map(), max_runs: runs(100)) do
        warnings = Contrast.warnings(colors)

        for %{scheme: scheme, foreground: fg, background: bg, ratio: ratio} <- warnings do
          palette = Map.merge(Palette.defaults()[scheme], colors[scheme] || %{})
          assert {fg, bg} in Palette.pairs()
          assert ratio <= 4.5
          assert_in_delta ratio, Contrast.ratio(palette[fg], palette[bg]), 0.01
        end

        for scheme <- Palette.schemes(),
            palette = Map.merge(Palette.defaults()[scheme], colors[scheme] || %{}),
            {fg, bg} <- Palette.pairs(),
            Contrast.ratio(palette[fg], palette[bg]) < 4.5 do
          assert Enum.any?(
                   warnings,
                   &(&1.scheme == scheme and &1.foreground == fg and &1.background == bg)
                 )
        end
      end
    end
  end

  describe "saved themes" do
    test "an admin's theme with random HTML is served clean" do
      admin = admin_fixture()

      check all(input <- html_fragment(), max_runs: runs(15)) do
        attrs = %{
          "name" => "T#{System.unique_integer([:positive])}",
          "head_html" => input,
          "footer_html" => input
        }

        # Saved, or refused with a reason (never raised).
        case Themes.create_theme(attrs, admin) do
          {:ok, theme} ->
            theme = Themes.get_theme!(theme.id)

            for place <- [:head, :footer] do
              html = Themes.html(theme, place, "n")
              assert HTMLSafety.unsafe(html, allow_tags: ["meta", "link"]) == []
            end

          {:error, %Ecto.Changeset{}} ->
            :ok
        end
      end
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "html/3 without scripts stays clean" do
      check all(
              input <- one_of([html_fragment(4), markdown(), any_text()]),
              max_runs: fuzz_runs()
            ) do
        assert_clean(input)
      end
    end
  end

  defp color_map do
    map(
      list_of({member_of(Palette.schemes()), member_of(Palette.tokens()), hex_color()},
        max_length: 8
      ),
      fn entries ->
        Enum.reduce(entries, %{}, fn {scheme, token, color}, acc ->
          Map.update(
            acc,
            scheme,
            %{token => String.downcase(color)},
            &Map.put(&1, token, String.downcase(color))
          )
        end)
      end
    )
  end
end
