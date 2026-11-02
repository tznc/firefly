defmodule FireflyWeb.Api.V1.CategoryJSON do
  @moduledoc "JSON representation of categories."
  alias Firefly.Forums.Category

  def data(%Category{} = category) do
    Map.take(category, [:id, :title, :slug, :inserted_at, :updated_at])
  end
end
