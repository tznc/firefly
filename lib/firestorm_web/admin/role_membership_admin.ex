defmodule FirestormWeb.Admin.RoleMembershipAdmin do
  @moduledoc "Kaffy admin for granting roles to users."
  use FirestormWeb.Admin.Logged, as: "role_membership"

  def index(_), do: [user_id: nil, role_id: nil, inserted_at: nil]
  def form_fields(_), do: [user_id: nil, role_id: nil]
end
