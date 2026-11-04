defmodule Firefly.RenderingPropertyTest do
  @moduledoc """
  Properties of `Firefly.Rendering`: rendering is total and its output is
  always safe, whatever members write; BBCode conversion is total; quotes
  and mentions round-trip.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Discussion.{Mentions, Quote}
  alias Firefly.HTMLSafety
  alias Firefly.Rendering.{BBCode, Markdown}

  # The only styles a post keeps: BBCode's colors and sizes.
  defp bbcode_style?(style),
    do: style =~ ~r/\A(color: (#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|[a-z]+)|font-size: [0-9]{2,3}%)\z/

  defp safe?(html), do: HTMLSafety.unsafe(html, allow_style: &bbcode_style?/1) == []

  defp assert_safe_render(input) do
    html = Markdown.render(input)
    assert is_binary(html)
    assert safe?(html), "unsafe output for #{inspect(input)}:\n#{html}"
  end

  describe "Markdown.render/3" do
    property "never raises and never lets scripts, handlers or script URLs through" do
      check all(input <- markdown(), max_runs: runs(150)) do
        assert_safe_render(input)
      end
    end

    property "is total on any text, invalid UTF-8 included" do
      check all(input <- any_text(), max_runs: runs(100)) do
        assert is_binary(Markdown.render(input))
      end
    end

    property "raw HTML is sanitized" do
      check all(input <- html_fragment(), max_runs: runs(150)) do
        assert_safe_render(input)
      end
    end

    property "BBCode links and images never carry a script URL" do
      check all(
              url <- script_url(),
              text <- adversarial_text(4),
              tag <- member_of(["url", "img", "URL", "Img"]),
              max_runs: runs(100)
            ) do
        assert_safe_render("[#{tag}=#{url}]#{text}[/#{tag}]")
        assert_safe_render("[#{tag}]#{url}[/#{tag}]")
      end
    end

    property "long input renders" do
      check all(input <- long_string(20_000), max_runs: runs(10)) do
        assert is_binary(Markdown.render(input))
      end
    end
  end

  describe "BBCode.to_markdown/2" do
    property "is total" do
      check all(input <- one_of([bbcode(), any_text()]), max_runs: runs(150)) do
        assert is_binary(BBCode.to_markdown(input))
      end
    end

    property "text without BBCode is left as it is" do
      check all(input <- adversarial_text(), max_runs: runs(100)) do
        input = String.replace(input, "[", "")
        assert BBCode.to_markdown(input) == input
      end
    end

    property "code is never converted" do
      check all(input <- bbcode(), max_runs: runs(100)) do
        code = "```\n" <> String.replace(input, "`", "") <> "\n```"
        assert BBCode.to_markdown(code) == code
      end
    end
  end

  describe "quotes" do
    property "a quote renders as a quote attributed to its author" do
      check all(
              body <- markdown(),
              username <- username(),
              id <- positive_integer(),
              max_runs: runs(50)
            ) do
        html = body |> Quote.build(username, "/t/x/#{id}#post-#{id}") |> Markdown.render()
        assert html =~ ~s(<blockquote class="quote">)

        assert html =~
                 ~r{<p class="quote-attribution"><a href="/t/x/#{id}\#post-#{id}"[^>]*>@#{username} said:</a></p>}

        assert safe?(html)
      end
    end

    property "any part of a post's text is in it, and is what gets quoted" do
      check all(
              words <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 10
                ),
              range <-
                bind(
                  integer(0..(length(words) - 1)),
                  &tuple({constant(&1), integer(&1..(length(words) - 1))})
                ),
              max_runs: runs(50)
            ) do
        body = Enum.join(words, " ")
        {from, to} = range
        selection = words |> Enum.slice(from..to) |> Enum.join(" ")
        assert Quote.in_post?(body, selection)
        assert Quote.build(body, "alice", "/t/x/1") =~ body
        assert Quote.build(body, "alice", "/t/x/1", selection) =~ "\n> #{selection}\n"
      end
    end

    property "text that isn't in the post is never quoted as the author's" do
      check all(
              body <- string(:alphanumeric, min_length: 1, max_length: 30),
              selection <- string(:alphanumeric, min_length: 31, max_length: 40),
              max_runs: runs(50)
            ) do
        refute Quote.in_post?(body, selection)
        refute Quote.build(body, "alice", "/t/x/1", selection) =~ selection
      end
    end
  end

  describe "mentions" do
    property "the names a post mentions are found, in order, once each" do
      check all(names <- list_of(username(), min_length: 1, max_length: 6), max_runs: runs(100)) do
        body = Enum.map_join(names, " and ", &"@#{&1}")
        assert Mentions.usernames(body) == Enum.uniq(names)
      end
    end

    property "mentions in quotes and code don't count" do
      check all(name <- username(), max_runs: runs(50)) do
        assert Mentions.usernames("> @#{name}") == []
        assert Mentions.usernames("`@#{name}`") == []
        assert Mentions.usernames("```\n@#{name}\n```") == []
      end
    end

    test "a mention of an existing user and a category reference link, and round-trip" do
      check all(name <- username(), slug <- slug(), max_runs: runs(10)) do
        user = user_fixture(%{username: "#{name}u#{System.unique_integer([:positive])}"})
        {:ok, category} = Firefly.Discussion.create_category(%{title: slug})

        html = Markdown.render("hi @#{user.username} see ##{category.slug}")
        assert html =~ ~s(href="#{Firefly.URLs.user_url(user)}")
        assert html =~ ~s(href="#{Firefly.URLs.category_url(category)}")
        assert html =~ "@#{user.username}"
        assert safe?(html)
      end
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "Markdown.render/3 stays safe" do
      check all(
              input <- one_of([markdown(), html_fragment(4), bbcode(), any_text()]),
              max_runs: fuzz_runs()
            ) do
        assert_safe_render(input)
      end
    end

    property "BBCode.to_markdown/2 is total" do
      check all(input <- one_of([bbcode(), any_text(), markdown()]), max_runs: fuzz_runs()) do
        assert is_binary(BBCode.to_markdown(input))
      end
    end
  end
end
