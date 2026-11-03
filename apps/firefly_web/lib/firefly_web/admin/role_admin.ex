defmodule FireflyWeb.Admin.RoleAdmin do
  @moduledoc "Kaffy admin for roles (e.g. \"admin\")."
  use FireflyWeb.Admin.Logged, as: "role"

  def index(_), do: [name: nil, inserted_at: nil]
  def form_fields(_), do: [name: nil]
end
