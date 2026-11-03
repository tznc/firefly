defmodule FireflyImport.MarkdownTest do
  use ExUnit.Case, async: true

  alias FireflyImport.Markdown

  test "converts HTML to Markdown" do
    html = """
    <h2>Title</h2>
    <p>Some <strong>bold</strong>, <em>italic</em> and <del>gone</del> text with <code>code</code>,
    a <a href="https://example.com">link</a> and <a href="https://example.com">https://example.com</a>.<br>Next line.</p>
    <p><img src="/images/cat.png" alt="A cat"></p>
    <ul><li>one</li><li>two<ol><li>nested</li></ol></li></ul>
    <blockquote><p>Quoted</p><p>twice</p></blockquote>
    <pre><code class="lang-elixir">IO.puts("*hi*")
    </code></pre>
    <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2 | 3</td></tr></table>
    <hr><p>Snake_case and *stars*</p><script>alert(1)</script>
    """

    assert Markdown.from_html(html) == """
           ## Title

           Some **bold**, *italic* and ~~gone~~ text with `code`, a [link](https://example.com) and <https://example.com>.  
           Next line.

           ![A cat](/images/cat.png)

           - one
           - two
             1. nested

           > Quoted
           >
           > twice

           ```elixir
           IO.puts("*hi*")
           ```

           | A | B |
           | --- | --- |
           | 1 | 2 \\| 3 |

           ---

           Snake\\_case and \\*stars\\*\
           """
  end

  test "converts BBCode to Markdown" do
    assert Markdown.from_bbcode("[b]Hi[/b] [url=https://example.com]there[/url]") ==
             "<strong>Hi</strong> [there](<https://example.com>)"

    assert Markdown.from_bbcode(nil) == ""
    assert Markdown.from_html(nil) == ""
  end
end
