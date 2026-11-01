defmodule FirestormWeb.Admin.RoleMembershipAdmin do
  @moduledoc "Kaffy admin for granting roles to users."
  use FirestormWeb.Admin.Logged, as: "role_membership"

  def index(_), do: [user_id: nil, role_id: nil, inserted_at: nil]
  # Who holds which role changes only by creating or deleting a membership,
  # which the staff log records as `role.grant`/`role.revoke`; editing one in
  # place would be a grant and a revoke logged as a generic update.
  def form_fields(_), do: [user_id: %{update: :readonly}, role_id: %{update: :readonly}]
end
