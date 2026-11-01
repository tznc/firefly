defmodule FirestormWeb.Web.Api.V1.UserJSON do
  @moduledoc "JSON representation of users (public fields only)."
  alias FirestormWeb.Forums.User

  def data(%User{} = user) do
    user
    |> Map.take([:id, :name, :username, :inserted_at, :updated_at])
    |> Map.put(:avatar_url, User.avatar_url(user))
  end
end
