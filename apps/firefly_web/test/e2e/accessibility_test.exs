defmodule FireflyWeb.E2E.AccessibilityTest do
  @moduledoc """
  Runs [axe-core](https://github.com/dequelabs/axe-core) over the pages
  members and staff use most, in both themes, and fails on any serious or
  critical violation. The browser's own accessibility tree is what's
  checked, so this covers the LiveView's connected markup, not the dead
  render.
  """
  use FireflyWeb.E2ECase, async: false

  alias Firefly.{Chat, Discussion, SiteSettings}

  @axe Path.join([__DIR__, "..", "..", "assets", "node_modules", "axe-core", "axe.min.js"])
       |> Path.expand()

  # What axe should hold the page to: WCAG 2.1 A and AA, plus the best
  # practices for landmarks, headings and names.
  @tags ~w(wcag2a wcag2aa wcag21a wcag21aa best-practice)

  @serious ~w(serious critical)

  setup_all do
    unless File.exists?(@axe) do
      raise "axe-core is missing: run npm ci --prefix apps/firefly_web/assets"
    end

    %{axe: File.read!(@axe)}
  end

  setup do
    admin = admin_fixture("ada")
    member = member_fixture("bob")
    {:ok, category} = Discussion.create_category(%{title: "Elixir", description: "The BEAM"})

    {:ok, thread} =
      Discussion.create_thread(category, member, %{
        title: "OTP is cool",
        body: "Don't you think? Here's a [link](https://example.com) and `code`.",
        tags: "otp"
      })

    {:ok, _reply} = Discussion.create_post(thread, admin, %{body: "It is."})
    # The categories admin's nested, reorderable lists.
    {:ok, _} = Discussion.create_category(%{title: "Nerves", parent_id: category.id})
    {:ok, _} = SiteSettings.update(%{"chat_enabled" => "true"}, admin)
    on_exit(&SiteSettings.clear_cache/0)
    {:ok, channel} = Chat.create_channel(%{name: "general"}, admin)
    {:ok, _} = Chat.send_message(channel, member, %{body: "Hello chat"})

    %{admin: admin, member: member, category: category, thread: thread, channel: channel}
  end

  # One test per page (each holds the database sandbox only while it audits
  # its page; a single test walking every page outlasted the sandbox's
  # ownership timeout on a busy machine). Paths name what setup made.
  @pages [
    {"home", "/"},
    {"categories", "/categories"},
    {"category", "/categories/:category"},
    {"thread", "/categories/:category/threads/:thread"},
    {"composer", "/categories/:category/threads/:thread/posts/new"},
    {"new thread", "/categories/:category/threads/new"},
    {"chat", "/chat/c/:channel_slug/:channel"},
    {"search", "/search?q=cool"},
    {"users", "/users"},
    {"notifications", "/notifications"},
    {"settings", "/settings/profile"},
    {"interface settings", "/settings/interface"},
    {"staff dashboard", "/staff/dashboard"},
    {"review queue", "/staff/review"},
    {"site settings", "/staff/settings"},
    {"admin home", "/staff?q=users"},
    {"users admin", "/staff/users"},
    {"user admin", "/staff/users/:member"},
    {"categories admin", "/staff/categories"},
    {"emails admin", "/staff/emails"},
    {"email previews", "/staff/emails?tab=previews"},
    {"screening", "/staff/screening"},
    {"themes", "/staff/themes"},
    {"theme editor", "/staff/themes/:theme"},
    {"packages", "/staff/packages"},
    {"package theme", "/staff/themes/:packaged"}
  ]

  for {name, template} <- @pages do
    test "the #{name} page has no serious accessibility violations", context do
      context.conn
      |> log_in("ada")
      |> visit(page_path(unquote(template), context))
      |> assert_has("[data-phx-main].phx-connected")
      |> audit(context.axe, unquote(name))
    end
  end

  defp page_path(template, context) do
    Regex.replace(~r/:(\w+)/, template, fn _, key -> to_string(page_id(key, context)) end)
  end

  defp page_id("category", context), do: context.category.id
  defp page_id("thread", context), do: context.thread.id
  defp page_id("channel", context), do: context.channel.id
  defp page_id("channel_slug", context), do: context.channel.slug
  defp page_id("member", context), do: context.member.id

  defp page_id("theme", context) do
    {:ok, theme} = Firefly.Themes.create_theme(%{"name" => "Ocean"}, context.admin)
    theme.id
  end

  defp page_id("packaged", context), do: theme_package!(context.admin).id

  # Not audited: the jobs dashboard (`/staff/jobs`, see FireflyWeb.JobsDashboard)
  # is Oban Web's own markup, under its own layout and stylesheet, which axe
  # finds serious violations in (color contrast in its state counts and
  # headers; the refresh menu toggle's name not matching its text) that we
  # can't fix from here. It's an admin-only operations tool; report them
  # upstream rather than patch its CSS.

  test "the dark theme has no contrast violations either", context do
    %{conn: conn, category: category, thread: thread} = context

    conn
    |> log_in("ada")
    |> visit("/categories/#{category.id}/threads/#{thread.id}")
    |> assert_has("[data-phx-main].phx-connected")
    |> evaluate("document.documentElement.setAttribute('data-theme', 'firefly-dark')")
    |> audit(context.axe, "thread (dark)")
    |> visit("/settings/interface")
    |> assert_has("[data-phx-main].phx-connected")
    |> evaluate("document.documentElement.setAttribute('data-theme', 'firefly-dark')")
    |> audit(context.axe, "settings (dark)")
  end

  test "a visitor's pages have none either", context do
    %{conn: conn, category: category, thread: thread} = context

    for path <- ["/", "/login", "/register", "/categories/#{category.id}/threads/#{thread.id}"] do
      conn
      |> visit(path)
      |> assert_has("[data-phx-main].phx-connected")
      |> audit(context.axe, "visitor #{path}")
    end
  end

  # A theme package, installed: the packages list and the theme editor show it.
  defp theme_package!(admin) do
    zip =
      Firefly.Packages.Archive.build(
        %{
          "id" => "dusk",
          "name" => "Dusk",
          "version" => "1.0.0",
          "firefly" => "~> 1.0",
          "tags" => ["theme", "dark"],
          "settings" => [
            %{
              "key" => "radius",
              "type" => "integer",
              "default" => 4,
              "label" => "Radius",
              "help" => ""
            },
            %{
              "key" => "shadow",
              "type" => "boolean",
              "default" => false,
              "label" => "Shadow",
              "help" => ""
            }
          ],
          "theme" => %{"css" => "theme.css"}
        },
        %{"theme.css" => ".dusk {}"}
      )

    {:ok, archive} = Firefly.Packages.read(zip)
    {:ok, package} = Firefly.Packages.install(archive, admin)
    hd(Firefly.Themes.package_themes(package.id))
  end

  # Injects axe (once per page) and fails with what it found. Transitions
  # are switched off first: a sidebar or toast caught mid-fade blends its
  # text into the background, which axe reads as a contrast failure that
  # no reader would ever see (and which comes and goes with how fast the
  # machine is).
  @still """
  if (!document.getElementById("axe-no-motion")) {
    const style = document.createElement("style")
    style.id = "axe-no-motion"
    style.textContent = "*, *::before, *::after { transition: none !important; animation: none !important }"
    document.head.appendChild(style)
  }
  """

  defp audit(session, axe, page) do
    session
    |> evaluate(@still)
    |> evaluate("if (!window.axe) { #{axe} }")
    |> evaluate(
      """
      (async () => {
        const result = await window.axe.run(document, {
          runOnly: {type: "tag", values: #{Jason.encode!(@tags)}},
          resultTypes: ["violations"],
        })
        return result.violations.map(v => ({
          id: v.id,
          impact: v.impact,
          help: v.help,
          nodes: v.nodes.slice(0, 3).map(n => n.target.join(" ") + " :: " + n.failureSummary),
        }))
      })()
      """,
      fn violations ->
        serious = Enum.filter(violations, &(&1["impact"] in @serious))

        assert serious == [],
               "#{page} has #{length(serious)} serious accessibility violation(s):\n" <>
                 Enum.map_join(serious, "\n", &describe/1)
      end
    )
  end

  defp describe(violation) do
    "  [#{violation["impact"]}] #{violation["id"]}: #{violation["help"]}\n" <>
      Enum.map_join(violation["nodes"], "\n", &"    - #{&1}")
  end
end
