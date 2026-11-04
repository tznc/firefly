defmodule FireflyWeb.Api.V1.CategoryJSON do
  @moduledoc "JSON representation of categories."
  alias Firefly.Discussion.Category
  alias Firefly.URLs

  def data(%Category{} = category) do
    category
    |> Map.take([
      :id,
      :title,
      :slug,
      :description,
      :color,
      :position,
      :parent_id,
      :allow_accepted_answers,
      :inserted_at,
      :updated_at
    ])
    |> Map.merge(%{restricted: category.restricted, url: URLs.category_url(category)})
  end
end
