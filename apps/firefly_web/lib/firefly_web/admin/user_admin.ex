defmodule FireflyWeb.Admin.UserAdmin do
  @moduledoc """
  Users in the database admin. Password hashes are never shown, searched
  or editable here; accounts are created by signing up and deleted at
  `/staff/users`, which also handles everything else about them.
  """
  use FireflyWeb.Admin.Logged, as: "user"

  def index(_), do: [username: nil, name: nil, email: nil, trust_level: nil, inserted_at: nil]

  def form_fields(_), do: [username: nil, name: nil, email: nil]
  def search_fields(_), do: [:username, :name, :email]
  def default_actions(_), do: [:edit]
end
