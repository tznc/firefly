defmodule FirestormWeb.Web.Api.V1.CategoryJSON do
  @moduledoc "JSON representation of categories."
  alias FirestormWeb.Forums.Category

  def data(%Category{} = category) do
    Map.take(category, [:id, :title, :slug, :inserted_at, :updated_at])
  end
end
