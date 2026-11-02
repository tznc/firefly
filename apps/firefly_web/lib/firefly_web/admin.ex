defmodule FireflyWeb.Admin do
  @moduledoc """
  Resources shown in the Kaffy admin UI at `/admin`. Access is limited to
  users with the "admin" role (see `FireflyWeb.Plugs.RequireAdmin`).
  """

  alias FireflyWeb.Admin

  def resources(_conn) do
    [
      forums: [
        name: "Forums",
        resources: [
          category: [schema: Firefly.Discussion.Category, admin: Admin.CategoryAdmin],
          thread: [schema: Firefly.Discussion.Thread, admin: Admin.ThreadAdmin],
          post: [schema: Firefly.Discussion.Post, admin: Admin.PostAdmin]
        ]
      ],
      accounts: [
        name: "Accounts",
        resources: [
          user: [schema: Firefly.Accounts.User, admin: Admin.UserAdmin],
          role: [schema: Firefly.Groups.Role, admin: Admin.RoleAdmin],
          role_membership: [
            schema: Firefly.Groups.RoleMembership,
            admin: Admin.RoleMembershipAdmin
          ],
          notification: [
            schema: Firefly.Notifications.Notification,
            admin: Admin.NotificationAdmin
          ]
        ]
      ]
    ]
  end
end
