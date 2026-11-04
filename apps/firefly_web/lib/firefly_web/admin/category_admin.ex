defmodule FireflyWeb.Admin.CategoryAdmin do
  @moduledoc "Categories in the database admin. Slugs are generated from the title."
  use FireflyWeb.Admin.Logged, as: "category"
  use Gettext, backend: FireflyWeb.Gettext

  def index(_),
    do: [title: nil, slug: %{value: &to_string(&1.slug)}, position: nil, inserted_at: nil]

  def form_fields(_) do
    [
      title: nil,
      description: %{type: :textarea},
      color: nil,
      position: nil,
      parent_id: nil
    ]
  end

  def search_fields(_), do: [:title]

  def plural_name(_), do: "Categories"

  def custom_links(_schema) do
    [
      %{
        name: gettext("Back to the staff admin"),
        url: "/staff",
        location: :top,
        icon: "arrow-left",
        full_icon: "fas fa-arrow-left",
        order: 1
      }
    ]
  end
end
