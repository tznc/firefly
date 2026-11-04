defmodule FireflyWeb.Admin.RoleMembershipAdmin do
  @moduledoc "Group memberships (who holds which role) in the database admin."
  use FireflyWeb.Admin.Logged, as: "role_membership"

  def index(_), do: [user_id: nil, role_id: nil, owner: nil, inserted_at: nil]
  # Who holds which role changes only by creating or deleting a membership,
  # which the staff log records as `role.grant`/`role.revoke`; editing one in
  # place would be a grant and a revoke logged as a generic update.
  def form_fields(_), do: [user_id: %{update: :readonly}, role_id: %{update: :readonly}]
  def default_actions(_), do: [:new, :delete]
  def singular_name(_), do: "Group membership"
end
