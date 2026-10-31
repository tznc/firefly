defmodule FirestormWeb.Admin.CategoryAdmin do
  @moduledoc "Kaffy admin for categories. Slugs are generated from the title."
  def index(_), do: [title: nil, slug: %{value: &to_string(&1.slug)}, inserted_at: nil]
  def form_fields(_), do: [title: nil]
  def search_fields(_), do: [:title]
end
