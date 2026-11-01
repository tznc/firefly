defmodule FirestormWeb.QuoteTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.{Markdown, Quote}

  @body "Supervisors **restart** children.\n\nThat's the *whole* trick & more."
  @url "/categories/1/threads/2#post-3"

  test "quotes the whole post with an attribution linking back" do
    assert Quote.build(@body, "alice", @url) == """
           > [@alice said:](/categories/1/threads/2#post-3)
           >
           > Supervisors **restart** children.
           >
           > That's the *whole* trick & more.

           """
  end

  test "quotes just a selection that is in the post" do
    assert Quote.build(@body, "alice", @url, " children.") =~ "\n>\n> children.\n\n"
    # As selected from the rendered post (no markdown), across lines
    assert Quote.build(@body, "alice", @url, "restart children.\nThat's the whole trick & more") =~
             "> restart children.\n> That's the whole trick & more\n\n"
  end

  test "falls back to the whole post for text that isn't in it" do
    for forged <- ["I never said this", "", "   ", nil, String.duplicate("a", 5_001)] do
      assert Quote.build(@body, "alice", @url, forged) == Quote.build(@body, "alice", @url)
    end
  end

  test "renders the attribution as a quote header" do
    html = Markdown.render(Quote.build("hello", "alice", @url) <> "my reply")

    assert html =~
             ~s(<blockquote class="quote">\n<p class="quote-attribution"><a href="/categories/1/threads/2#post-3")

    assert html =~ "@alice said:</a></p>"
    assert html =~ "<p>my reply</p>"
    # Ordinary blockquotes are left alone
    assert Markdown.render("> just a quote") =~ "<blockquote>\n<p>just a quote</p>"
  end
end
