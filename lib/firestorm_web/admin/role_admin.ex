defmodule FirestormWeb.Admin.RoleAdmin do
  @moduledoc "Kaffy admin for roles (e.g. \"admin\")."
  def index(_), do: [name: nil, inserted_at: nil]
  def form_fields(_), do: [name: nil]
end
