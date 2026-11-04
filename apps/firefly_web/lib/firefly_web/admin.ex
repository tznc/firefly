defmodule FireflyWeb.Admin do
  @moduledoc """
  The database admin at `/staff/db`: Kaffy, listing and editing the
  site's records as they're stored. It's optional and secondary: the
  staff admin at `/staff` is how the site is run, and does it through the
  contexts, with their checks and side effects; edits here skip those.

  It's off until an admin turns on the `enable_database_admin` site
  setting (a 404 before, see `FireflyWeb.Plugs.DatabaseAdmin`), and then
  for admins only, checked on every request (`FireflyWeb.Plugs.RequireAdmin`).
  Every create, update and delete is in the staff log
  (`FireflyWeb.Admin.Logged`). Secrets aren't shown: password hashes,
  plugins' bundles, code, secrets and settings, secret site settings; API
  keys, two-factor secrets and passkeys aren't listed at all.
  """

  alias FireflyWeb.Admin

  def resources(_conn) do
    [
      content: [
        name: "Content",
        resources: [
          category: [schema: Firefly.Discussion.Category, admin: Admin.CategoryAdmin],
          thread: [schema: Firefly.Discussion.Thread, admin: Admin.ThreadAdmin],
          post: [schema: Firefly.Discussion.Post, admin: Admin.PostAdmin],
          tag: [schema: Firefly.Discussion.Tag, admin: Admin.TagAdmin],
          tag_group: [schema: Firefly.Discussion.TagGroup, admin: Admin.TagGroupAdmin]
        ]
      ],
      people: [
        name: "People",
        resources: [
          user: [schema: Firefly.Accounts.User, admin: Admin.UserAdmin],
          group: [schema: Firefly.Groups.Role, admin: Admin.RoleAdmin],
          group_membership: [
            schema: Firefly.Groups.RoleMembership,
            admin: Admin.RoleMembershipAdmin
          ],
          badge: [schema: Firefly.Badges.Badge, admin: Admin.BadgeAdmin]
        ]
      ],
      configuration: [
        name: "Configuration",
        resources: [
          site_setting: [
            schema: Firefly.SiteSettings.SiteSetting,
            admin: Admin.SiteSettingAdmin
          ],
          theme: [schema: Firefly.Themes.Theme, admin: Admin.ThemeAdmin],
          plugin: [schema: Firefly.Plugins.InstalledPlugin, admin: Admin.PluginAdmin]
        ]
      ],
      email: [
        name: "Email",
        resources: [
          email_log: [schema: Firefly.Notifications.EmailLog, admin: Admin.EmailLogAdmin]
        ]
      ]
    ]
  end
end
