defmodule FirestormWeb.MarkdownTest do
  use ExUnit.Case, async: true
  alias FirestormWeb.Markdown

  test "renders basic things" do
    assert "<p>foo</p>" == Markdown.render("foo")
  end

  test "renders nil as an empty string" do
    assert "" == Markdown.render(nil)
  end

  test "renders GFM blocks with our preferred code class prefix" do
    markdown = """
    Here's some Elixir code:

    ```elixir
    defmodule Foo do
      def bar, do: "baz"
    end
    ```
    """

    expected = """
    <p>Here's some Elixir code:</p>
    <pre class="line-numbers"><code class="language-elixir">defmodule Foo do
      def bar, do: "baz"
    end
    </code></pre>\
    """

    assert expected == Markdown.render(markdown)
  end

  test "renders soft line breaks as <br>" do
    assert "<p>a<br>\nb</p>" == Markdown.render("a\nb")
  end

  test "autolinks URLs" do
    for url <-
          ~w(http://slashdot.org http://www.slashdot.org https://slashdot.org https://www.slashdot.org) do
      assert ~s(<p><a href="#{url}" rel="noopener noreferrer">#{url}</a></p>) ==
               Markdown.render(url)
    end

    # NOTE: This was the source of a bug, discovered on 2017-07-13. Using the
    # source post itself to ensure this one never shows up again.
    source =
      "My side project is dwarlixir - a madman's attempt to build a Dwarf-Fortress-like game with (currently) a text-based interface in Elixir, with everything being a process. https://github.com/trevoke/dwarlixir\r\n\r\nProfessionally I'm working on https://exeq.com - Elixir back-end! :D"

    assert Regex.match?(
             ~r{ <a href="https://github.com/trevoke/dwarlixir"},
             Markdown.render(source)
           )
  end

  test "converts words like :poop: into their emoji unicode representation" do
    assert "<p>This 💩🔥 is great!</p>" == Markdown.render("This :poop::fire: is great!")
  end

  test "does not convert emoji shortcodes inside code" do
    assert "<p><code>:poop:</code></p>" == Markdown.render("`:poop:`")
  end

  describe "sanitization" do
    test "strips script tags" do
      refute Markdown.render("<script>alert(1)</script>") =~ "<script"
    end

    test "strips event handler attributes" do
      html = Markdown.render(~s{<b onclick="alert(1)">bold</b> <img src="x" onerror="alert(1)">})
      refute html =~ "onclick"
      refute html =~ "onerror"
      assert html =~ "<b>bold</b>"
    end

    test "strips javascript: link targets" do
      refute Markdown.render("[x](javascript:alert(1))") =~ "javascript:"
    end

    test "escapes a literal <pre> in text rather than adding a class to it" do
      refute Markdown.render("`<pre>`") =~ ~s(<pre class=)
    end
  end
end
