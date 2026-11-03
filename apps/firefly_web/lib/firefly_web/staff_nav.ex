defmodule FireflyWeb.StaffNav do
  @moduledoc """
  The pages of the staff admin at `/staff`, in the sections its sidebar
  shows (see `FireflyWeb.Layouts.staff_nav/1`), each with the permission
  it needs (see `Firefly.Discussion.Policy`) and words to find it by in the
  admin's search (`FireflyWeb.StaffLive.Index`). A viewer sees only the
  pages they may use: moderators get the moderation pages, admins all of
  them.
  """

  use Gettext, backend: FireflyWeb.Gettext

  import FireflyWeb.Authorization, only: [can?: 2]

  @doc """
  The sections with the pages `user` may use: `{title, pages}`, each page
  a map with `path`, `label`, `icon` and `keywords`. Sections left empty
  are dropped.
  """
  def sections(user) do
    for {title, pages} <- all(),
        pages = Enum.filter(pages, &can?(user, &1.permission)),
        pages != [],
        do: {title, pages}
  end

  @doc "Every page `user` may use, in sidebar order."
  def pages(user), do: Enum.flat_map(sections(user), &elem(&1, 1))

  @doc """
  The pages `user` may use whose label, section or keywords contain every
  word of `query` (any case).
  """
  def search(user, query) do
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    for {section, pages} <- sections(user),
        page <- pages,
        text = String.downcase(Enum.join([section, page.label | page.keywords], " ")),
        words != [] and Enum.all?(words, &String.contains?(text, &1)),
        do: Map.put(page, :section, section)
  end

  defp all do
    [
      {gettext("Overview"),
       [
         page("/staff", gettext("Admin home"), "hero-home", :view_admin, ~w(start search)),
         page(
           "/staff/dashboard",
           gettext("Dashboard"),
           "hero-chart-bar",
           :view_reports,
           ~w(stats overview)
         ),
         page(
           "/staff/reports",
           gettext("Reports"),
           "hero-document-chart-bar",
           :view_reports,
           ~w(csv statistics)
         )
       ]},
      {gettext("People"),
       [
         page(
           "/staff/users",
           gettext("Users"),
           "hero-users",
           :view_users,
           ~w(members accounts approve suspend silence impersonate merge anonymize)
         ),
         page(
           "/staff/groups",
           gettext("Groups"),
           "hero-user-group",
           :manage_groups,
           ~w(roles members owners)
         ),
         page(
           "/staff/badges",
           gettext("Badges"),
           "hero-trophy",
           :manage_badges,
           ~w(grant awards)
         ),
         page(
           "/staff/api-keys",
           gettext("API keys"),
           "hero-command-line",
           :manage_api_keys,
           ~w(tokens api)
         )
       ]},
      {gettext("Content"),
       [
         page(
           "/staff/categories",
           gettext("Categories"),
           "hero-squares-2x2",
           :manage_category,
           ~w(order permissions subcategories)
         ),
         page("/staff/tags", gettext("Tag groups"), "hero-tag", :manage_tags, ~w(tags synonyms)),
         page(
           "/staff/uploads",
           gettext("Uploads"),
           "hero-photo",
           :manage_uploads,
           ~w(files images attachments)
         ),
         page(
           "/staff/emoji",
           gettext("Emoji"),
           "hero-face-smile",
           :manage_emoji,
           ~w(custom emoji)
         )
       ]},
      {gettext("Moderation"),
       [
         page(
           "/staff/review",
           gettext("Review"),
           "hero-inbox-stack",
           :review,
           ~w(queue flags approve)
         ),
         page(
           "/staff/watched-words",
           gettext("Watched words"),
           "hero-eye",
           :manage_watched_words,
           ~w(censor block words)
         ),
         page(
           "/staff/screening",
           gettext("Screening"),
           "hero-shield-exclamation",
           :manage_screening,
           ~w(screened blocked emails ips urls domains spam)
         ),
         page(
           "/staff/log",
           gettext("Staff log"),
           "hero-clipboard-document-list",
           :view_staff_log,
           ~w(audit actions history)
         )
       ]},
      {gettext("Communication"),
       [
         page(
           "/staff/emails",
           gettext("Emails"),
           "hero-envelope",
           :manage_emails,
           ~w(mail sent log test preview templates)
         ),
         page(
           "/staff/webhooks",
           gettext("Webhooks"),
           "hero-bolt",
           :manage_webhooks,
           ~w(events integrations)
         )
       ]},
      {gettext("Configuration"),
       [
         page(
           "/staff/settings",
           gettext("Site settings"),
           "hero-adjustments-horizontal",
           :manage_site_settings,
           ~w(configuration options)
         ),
         page(
           "/staff/plugins",
           gettext("Plugins"),
           "hero-puzzle-piece",
           :manage_plugins,
           ~w(extensions)
         ),
         page("/staff/ai", "AI", "hero-sparkles", :manage_ai, ~w(llm models providers summaries)),
         page(
           "/staff/embedding",
           gettext("Embedding"),
           "hero-code-bracket",
           :manage_embedding,
           ~w(comments blog)
         ),
         page(
           "/staff/discourse-connect",
           "DiscourseConnect",
           "hero-key",
           :manage_sso_clients,
           ~w(sso login)
         )
       ]},
      {gettext("Maintenance"),
       [
         page(
           "/staff/backups",
           gettext("Backups"),
           "hero-archive-box-arrow-down",
           :manage_backups,
           ~w(restore read-only)
         ),
         page(
           "/staff/import",
           gettext("Import"),
           "hero-arrow-down-tray",
           :manage_imports,
           ~w(migrate discourse phpbb)
         ),
         page(
           "/staff/upgrade",
           gettext("Upgrade"),
           "hero-arrow-up-circle",
           :manage_upgrades,
           ~w(version update release)
         )
       ]}
    ]
  end

  defp page(path, label, icon, permission, keywords),
    do: %{path: path, label: label, icon: icon, permission: permission, keywords: keywords}
end
