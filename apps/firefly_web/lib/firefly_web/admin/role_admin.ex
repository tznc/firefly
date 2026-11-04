defmodule FireflyWeb.Admin.RoleAdmin do
  @moduledoc "Groups (roles, e.g. \"admin\") in the database admin."
  use FireflyWeb.Admin.Logged, as: "role"

  def index(_), do: [name: nil, visibility: nil, membership: nil, inserted_at: nil]
  def form_fields(_), do: [name: nil]
  def search_fields(_), do: [:name]
  def singular_name(_), do: "Group"
end
