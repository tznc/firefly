defmodule FirestormWeb.Admin do
  @moduledoc """
  Resources shown in the Kaffy admin UI at `/admin`. Access is limited to
  users with the "admin" role (see `FirestormWeb.Web.Plugs.RequireAdmin`).
  """

  alias FirestormWeb.{Admin, Forums}

  def resources(_conn) do
    [
      forums: [
        name: "Forums",
        resources: [
          category: [schema: Forums.Category, admin: Admin.CategoryAdmin],
          thread: [schema: Forums.Thread, admin: Admin.ThreadAdmin],
          post: [schema: Forums.Post, admin: Admin.PostAdmin]
        ]
      ],
      accounts: [
        name: "Accounts",
        resources: [
          user: [schema: Forums.User, admin: Admin.UserAdmin],
          role: [schema: Forums.Role, admin: Admin.RoleAdmin],
          role_membership: [schema: Forums.RoleMembership, admin: Admin.RoleMembershipAdmin],
          notification: [schema: Forums.Notification, admin: Admin.NotificationAdmin]
        ]
      ]
    ]
  end
end
