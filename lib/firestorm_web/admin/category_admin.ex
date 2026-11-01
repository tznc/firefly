defmodule FirestormWeb.Admin.CategoryAdmin do
  @moduledoc "Kaffy admin for categories. Slugs are generated from the title."
  def index(_), do: [title: nil, slug: %{value: &to_string(&1.slug)}, inserted_at: nil]
  def form_fields(_), do: [title: nil]
  def search_fields(_), do: [:title]

  def custom_links(_schema) do
    [
      %{
        name: "Back to Firefly",
        url: "/",
        location: :top,
        icon: "arrow-left",
        full_icon: "fas fa-arrow-left",
        order: 1
      }
    ]
  end
end
