defmodule FirestormWeb.BBCodeTest do
  use FirestormWeb.DataCase, async: true

  alias FirestormWeb.{BBCode, Markdown, SiteSettings}

  defp render(text), do: Markdown.render(text)

  describe "same HTML as the Markdown equivalent" do
    test "inline styles" do
      assert render("[b]bold[/b] [I]it[/i] [s]gone[/s]") == render("**bold** *it* ~~gone~~")
      assert render("[u]under[/u]") == "<p><u>under</u></p>"
    end

    test "quotes, with an attribution only for a username" do
      assert render("[quote]Hello\n\nworld[/quote]") == render("> Hello\n>\n> world")

      assert render("[quote=alice]Hi[/quote]") == render("> @alice said:\n>\n> Hi")
      assert render(~s{[quote="alice"]Hi[/quote]}) == render("> @alice said:\n>\n> Hi")
      assert render("[quote=<b>x</b>]Hi[/quote]") == render("> Hi")
    end

    test "code blocks and spans, with nothing inside converted" do
      assert render("[code]x = [b]1[/b]\ny[/code]") == render("```\nx = [b]1[/b]\ny\n```")
      assert render("[code][i]x[/i][/code]") == render("` [i]x[/i] `")
    end

    test "links and images, http(s) only" do
      assert render("[url]https://a.example/x[/url]") == render("<https://a.example/x>")

      assert render("[url=https://a.example]A [b]site[/b][/url]") ==
               render("[A **site**](https://a.example)")

      assert render("[img]https://a.example/y.png[/img]") ==
               render("![](https://a.example/y.png)")
    end

    test "lists, nested and numbered" do
      assert render("[list][*]one[*]two[list=1][*]a[*]b[/list][/list]") ==
               render("- one\n- two\n  1. a\n  1. b")
    end
  end

  describe "sanitized" do
    test "javascript and other schemes stay text" do
      for text <- [
            "[url=javascript:alert(1)]x[/url]",
            "[url]javascript:alert(1)[/url]",
            "[img]javascript:alert(1)[/img]",
            "[url=https://a.example onclick=alert(1)]x[/url]",
            "[img]data:image/svg+xml,<svg onload=alert(1)>[/img]"
          ] do
        html = render(text)
        refute html =~ ~r/(href|src)="(javascript|data):/
        refute html =~ ~r/<[^>]+\son\w+=/
        refute html =~ "<img"
      end
    end

    test "color and size only take safe values" do
      assert render("[color=red]r[/color] [color=#A0b]h[/color]") ==
               ~s(<p><span style="color: red">r</span> <span style="color: #a0b">h</span></p>)

      assert render("[size=5]big[/size] [size=80%]small[/size]") ==
               ~s(<p><span style="font-size: 150%">big</span> <span style="font-size: 80%">small</span></p>)

      for text <- [
            "[color=red;background:url(javascript:alert(1))]x[/color]",
            ~s{[color="red" onmouseover="alert(1)"]x[/color]},
            "[color=expression(alert(1))]x[/color]",
            "[size=999]x[/size]",
            "[size=1;position:fixed]x[/size]"
          ] do
        assert render(text) == "<p>x</p>"
      end
    end

    test "markup inside tags is still sanitized" do
      html = render("[b]<script>alert(1)</script><img src=x onerror=alert(1)>[/b]")
      refute html =~ "<script"
      refute html =~ "onerror"
    end
  end

  test "spoilers, inline and spanning paragraphs" do
    assert render("a [spoiler]secret[/spoiler]") ==
             ~s(<p>a <span class="spoiler">secret</span></p>)

    assert render("[spoiler]one\n\ntwo[/spoiler]") =~
             ~s(<div class="spoiler">\n<p>one</p>\n<p>two</p>\n</div>)
  end

  test "Markdown code is left alone" do
    for text <- [
          "`[b]x[/b]`",
          "```\n[b]x[/b]\n```",
          "~~~\n[quote]x[/quote]\n~~~",
          "para\n\n    [b]x[/b]",
          "``a ` [b]x[/b]``"
        ] do
      refute render(text) =~ "<strong>"
      refute render(text) =~ "<blockquote>"
    end

    assert render("`[b]x[/b]` [b]y[/b]") == "<p><code>[b]x[/b]</code> <strong>y</strong></p>"
  end

  test "unmatched and unknown tags stay as written" do
    assert render("[b]open [i]x[/b] [/i] [*] [foo]y[/foo]") ==
             "<p><strong>open [i]x</strong> [/i] [*] [foo]y[/foo]</p>"
  end

  test "plugins' shortcodes and the site setting win" do
    assert BBCode.to_markdown("[spoiler]x[/spoiler] [b]y[/b]", ["spoiler"]) ==
             "[spoiler]x[/spoiler] <strong>y</strong>"

    {:ok, _} = SiteSettings.update(%{"bbcode" => "false"}, admin())
    assert render("[b]y[/b]") == "<p>[b]y[/b]</p>"
  end

  defp admin do
    {:ok, user} =
      FirestormWeb.Forums.register_user(%{
        username: "admin#{System.unique_integer([:positive])}",
        email: "admin#{System.unique_integer([:positive])}@example.com",
        password: "password123"
      })

    {:ok, role} = FirestormWeb.Forums.create_role("admin")
    {:ok, _} = FirestormWeb.Forums.add_role(user, role)
    user
  end
end
