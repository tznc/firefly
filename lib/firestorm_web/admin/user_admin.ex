defmodule FirestormWeb.Admin.UserAdmin do
  @moduledoc """
  Kaffy admin for users. Password hashes and API tokens are never shown or
  editable here.
  """
  use FirestormWeb.Admin.Logged, as: "user"

  def index(_), do: [username: nil, name: nil, email: nil, inserted_at: nil]
  def form_fields(_), do: [username: nil, name: nil, email: nil]
  def search_fields(_), do: [:username, :name, :email]
end
