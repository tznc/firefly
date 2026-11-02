defmodule FirestormWeb.RichMarkdownTest do
  use FirestormWeb.Web.ConnCase

  @moduletag :capture_log

  import FirestormWeb.PluginHelpers

  alias FirestormWeb.{Markdown, Repo, SiteSettings}
  alias FirestormWeb.Plugins.Health

  setup do
    %{admin: admin_fixture()}
  end

  defp off(admin, setting), do: {:ok, _} = SiteSettings.update(%{setting => "false"}, admin)

  describe "spoilers" do
    test ">!text!< and [spoiler], not in code" do
      assert Markdown.render("It was >!the **butler**!< all along") ==
               ~s(<p>It was <span class="spoiler">the <strong>butler</strong></span> all along</p>)

      assert Markdown.render("`>!code!<`\n\n    >!indented!<") =~ "<code>&gt;!code!&lt;</code>"
      refute Markdown.render("`>!code!<`\n\n    >!indented!<") =~ "spoiler"
      # Not a blockquote any more, nor spanning lines.
      assert Markdown.render(">!whole line!<") ==
               ~s(<p><span class="spoiler">whole line</span></p>)

      refute Markdown.render(">!one\ntwo!<") =~ "spoiler"
    end

    test "carry no markup the sanitizer wouldn't allow anyway" do
      html = Markdown.render(">!<img src=x onerror=alert(1)><script>alert(1)</script>!<")
      assert html =~ ~s(<span class="spoiler">)
      refute html =~ "onerror"
      refute html =~ "<script"
    end

    test "can be turned off", %{admin: admin} do
      off(admin, "spoilers")
      assert Markdown.render(">!x!< [spoiler]y[/spoiler]") =~ "[spoiler]y[/spoiler]"
      refute Markdown.render(">!x!< [spoiler]y[/spoiler]") =~ "spoiler\""
    end
  end

  describe "math" do
    test "inline and display, as text for KaTeX" do
      assert Markdown.render("Area: $\\pi r^2$") ==
               ~s(<p>Area: <span data-math-style="inline">\\pi r^2</span></p>)

      assert Markdown.render("$$\n\\frac{a}{b}\n$$") =~
               ~s(<span data-math-style="display">\n\\frac{a}{b}\n</span>)

      # Markup in math is text.
      assert Markdown.render("$<script>alert(1)</script>$") =~
               ~s{<span data-math-style="inline">&lt;script&gt;alert(1)&lt;/script&gt;</span>}
    end

    test "only the two math styles get through the sanitizer" do
      html = Markdown.render(~s{<span data-math-style="evil" onclick="alert(1)">x</span>})
      assert html == "<p><span>x</span></p>"
    end

    test "can be turned off", %{admin: admin} do
      off(admin, "math")
      assert Markdown.render("$x$") == "<p>$x$</p>"
    end
  end

  describe "footnotes" do
    test "link to their text, scoped to the post" do
      html = Markdown.render("Fact[^1].\n\n[^1]: Source.")

      assert html =~
               ~s(<a href="#user-content-fn-preview-1" id="user-content-fnref-preview-1" rel="noopener noreferrer">1</a>)

      assert html =~ ~s(<li id="user-content-fn-preview-1">)
      assert html =~ ~s(href="#user-content-fnref-preview-1")
      assert html =~ "<section>"

      thread =
        thread_fixture(category_fixture(), user_fixture(), %{body: "Fact[^1].\n\n[^1]: Source."})

      [post] = Repo.preload(thread, :posts).posts
      html = Markdown.render(post.body, nil, post: post, thread: thread)
      assert html =~ ~s(id="user-content-fn-p#{post.id}-1")
    end

    test "user ids can't clash with the page's" do
      html = Markdown.render(~s{<li id="post-preview">a</li><a id="csrf-token" onclick="x">b</a>})
      assert html =~ ~s(id="user-content-post-preview")
      assert html =~ ~s(id="user-content-csrf-token")
      refute html =~ "onclick"
      refute Markdown.render(~s{<p id="x">p</p>}) =~ "id="
    end

    test "can be turned off", %{admin: admin} do
      off(admin, "footnotes")
      assert Markdown.render("Fact[^1].") == "<p>Fact[^1].</p>"
    end
  end

  describe "with plugins" do
    defp tagger(admin) do
      install_plugin!(
        admin,
        %{"id" => "tagger", "name" => "Tagger", "hooks" => ["render_post"]},
        %{
          "index.js" =>
            "exports.render_post = ({html}) => html + '<p>' + (html.includes('class=\"spoiler\"') ? 'saw spoiler' : 'no spoiler') + '</p>'"
        },
        enable: true
      )
    end

    test "see the new markup, keep it through their sanitizer, and re-run when it changes", %{
      admin: admin
    } do
      tagger(admin)
      body = ">!x!< $y$ z[^1]\n\n[^1]: n"
      thread = thread_fixture(category_fixture(), user_fixture(), %{body: body})
      [post] = Repo.preload(thread, :posts).posts
      render = fn -> Markdown.render(post.body, nil, post: post, thread: thread) end

      html = render.()
      assert html =~ "<p>saw spoiler</p>"
      assert html =~ ~s(<span data-math-style="inline">y</span>)
      assert html =~ ~s(id="user-content-fn-p#{post.id}-1")
      assert html =~ ~s(href="#user-content-fn-p#{post.id}-1")
      assert render.() == html
      assert Health.stats("tagger").calls == 1

      # A setting change changes the HTML, so the cache misses.
      off(admin, "spoilers")
      assert render.() =~ "<p>no spoiler</p>"
      assert Health.stats("tagger").calls == 2
    end
  end

  test "KaTeX is vendored, not loaded from a CDN", %{conn: conn} do
    for path <- ~w(/vendor/katex/katex.min.js /vendor/katex/katex.min.css) do
      assert conn |> get(path) |> response(200)
    end

    refute File.read!("assets/js/hooks.js") =~ ~r/cdn|jsdelivr|unpkg/i
  end
end
