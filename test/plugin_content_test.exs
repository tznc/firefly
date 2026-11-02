defmodule FirestormWeb.PluginContentTest do
  use FirestormWeb.Web.ConnCase

  @moduletag :capture_log

  import FirestormWeb.PluginHelpers

  alias FirestormWeb.{Forums, Markdown, Plugins, Repo}
  alias FirestormWeb.Plugins.Health
  alias FirestormWeb.Test.GreeterPlugin

  setup do
    admin = admin_fixture()

    thread =
      thread_fixture(category_fixture("Public"), user_fixture(), %{body: "Hello **world**"})

    [post] = Repo.preload(thread, :posts).posts
    %{admin: admin, thread: thread, post: post}
  end

  defp render(post, thread, body \\ nil),
    do: Markdown.render(body || post.body, nil, post: post, thread: thread)

  defp transformer(admin, id, js, extra \\ %{}) do
    install_plugin!(
      admin,
      Map.merge(%{"id" => id, "name" => id, "hooks" => ["render_post"]}, extra),
      %{"index.js" => js},
      enable: true
    )
  end

  @spoiler """
  exports.render_shortcodes = ({shortcodes}) =>
    shortcodes.map((s) => `<details><summary>${s.attrs.title || "Spoiler"}</summary>${s.content}</details>`);
  """

  defp spoiler_plugin(admin) do
    install_plugin!(
      admin,
      %{
        "id" => "spoiler",
        "name" => "Spoiler",
        "hooks" => ["render_shortcodes"],
        "shortcodes" => ["spoiler"],
        "composer_buttons" => [
          %{"label" => "Spoiler", "insert" => "[spoiler]{{selection}}[/spoiler]"}
        ]
      },
      %{"index.js" => @spoiler},
      enable: true
    )
  end

  test "without content plugins, posts render as before", %{post: post, thread: thread} do
    assert render(post, thread) == Markdown.render(post.body)
  end

  test "shortcodes render through their plugin, but not in code", %{
    admin: admin,
    post: post,
    thread: thread
  } do
    spoiler_plugin(admin)

    html =
      render(post, thread, """
      [spoiler title="Ending"]It was **him**[/spoiler] and [spoiler]short[/spoiler] and [unknown]x[/unknown]

      `[spoiler]in code[/spoiler]`
      """)

    assert html =~ ~s(<details><summary>Ending</summary>It was <strong>him</strong></details>)
    assert html =~ ~s(<summary>Spoiler</summary>short</details>)
    assert html =~ "[unknown]x[/unknown]"
    assert html =~ "<code>[spoiler]in code[/spoiler]</code>"
  end

  test "plugin output goes back through the sanitizer", %{
    admin: admin,
    post: post,
    thread: thread
  } do
    transformer(admin, "evil", ~S"""
    exports.render_post = ({html}) =>
      html + '<script>alert(1)</script><img src="x" onerror="alert(1)"><a href="javascript:alert(1)">x</a><iframe src="https://evil"></iframe><span class="note">ok</span>';
    """)

    html = render(post, thread)
    assert html =~ "<strong>world</strong>"
    assert html =~ ~s(<span class="note">ok</span>)
    refute html =~ "<script"
    refute html =~ "onerror"
    refute html =~ "javascript:"
    refute html =~ "<iframe"
  end

  test "transforms run in dependency order, then priority", %{
    admin: admin,
    post: post,
    thread: thread
  } do
    transformer(admin, "late", "exports.render_post = ({html}) => html + '<p>late</p>'", %{
      "priority" => 900
    })

    transformer(admin, "early", "exports.render_post = ({html}) => html + '<p>early</p>'", %{
      "priority" => 1
    })

    # Depends on "late", so it runs after it despite its priority.
    transformer(admin, "after-late", "exports.render_post = ({html}) => html + '<p>after</p>'", %{
      "priority" => 0,
      "dependencies" => %{"late" => "~> 1.0"}
    })

    assert render(post, thread) =~ ~r{<p>early</p>.*<p>late</p>.*<p>after</p>}s
  end

  test "a failing or slow plugin is skipped; the others still apply", %{
    admin: admin,
    post: post,
    thread: thread
  } do
    transformer(admin, "slow", "exports.render_post = () => { for (;;) {} }")
    transformer(admin, "broken", "exports.render_post = () => { throw new Error('nope') }")
    transformer(admin, "good", "exports.render_post = ({html}) => html + '<p>good</p>'")

    html = render(post, thread)
    assert html =~ "<strong>world</strong>"
    assert html =~ "<p>good</p>"
    assert [%{kind: "timeout"}] = Health.errors("slow")
    assert [%{kind: "js_error"}] = Health.errors("broken")
  end

  test "posts in private categories never reach plugins", %{admin: admin} do
    transformer(admin, "peek", "exports.render_post = ({html}) => html + '<p>seen</p>'")
    {:ok, role} = Forums.create_role("staff")
    {:ok, private} = Forums.create_category(%{title: "Staff", role_ids: [role.id]})
    thread = thread_fixture(private, admin)
    [post] = Repo.preload(thread, :posts).posts

    refute render(post, thread) =~ "seen"
    assert Health.stats("peek").calls == 0
  end

  test "results are cached until the plugins change", %{admin: admin, post: post, thread: thread} do
    settings = %{"settings" => [%{"key" => "word", "type" => "string", "default" => "one"}]}

    transformer(
      admin,
      "stamp",
      "exports.render_post = ({html}) => html + '<p>' + firefly.plugin.settings.word + '</p>'",
      settings
    )

    assert render(post, thread) =~ "<p>one</p>"
    assert render(post, thread) =~ "<p>one</p>"
    assert Health.stats("stamp").calls == 1

    {:ok, _} = Plugins.update_settings("stamp", %{"word" => "two"}, admin)
    assert render(post, thread) =~ "<p>two</p>"

    {:ok, _} = Plugins.disable("stamp", admin)
    refute render(post, thread) =~ "<p>two</p>"
  end

  test "core plugins can transform too", %{post: post, thread: thread} do
    defmodule Shouter do
      use FirestormWeb.Plugin, id: "shouter", name: "Shouter", version: "1.0.0", firefly: "~> 1.0"

      @impl true
      def render_post(_plugin, %{"html" => html}), do: {:ok, String.upcase(html)}
    end

    with_core_plugins([Shouter, GreeterPlugin], fn ->
      # Tags come back lowercase from the sanitizer.
      assert render(post, thread) =~ "HELLO <strong>WORLD</strong>"
    end)
  end

  test "the thread page shows transformed posts and the composer has plugin buttons",
       %{admin: admin, conn: conn, thread: thread} do
    spoiler_plugin(admin)
    {:ok, _} = Forums.create_post(thread, admin, %{body: "[spoiler]The butler[/spoiler]"})

    conn
    |> log_in_as(admin)
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}")
    |> assert_has("details summary", text: "Spoiler")
    |> assert_has("details", text: "The butler")
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")
    |> assert_has("button[data-insert='[spoiler]{{selection}}[/spoiler]']", text: "Spoiler")
  end

  test "a manifest with shortcodes needs the render_shortcodes hook" do
    assert {:error, message} =
             FirestormWeb.Plugin.Manifest.parse(
               %{
                 "id" => "sc",
                 "name" => "S",
                 "version" => "1.0.0",
                 "firefly" => "~> 1.0",
                 "shortcodes" => ["x"]
               },
               "upload"
             )

    assert message =~ "needs the render_shortcodes hook"
  end
end
