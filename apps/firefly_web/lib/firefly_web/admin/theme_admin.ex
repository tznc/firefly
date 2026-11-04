defmodule FireflyWeb.Admin.ThemeAdmin do
  @moduledoc """
  Themes in the database admin. Their colors, CSS and HTML are edited at
  `/staff/themes`, which checks and compiles them; here only their name,
  description and whether members may pick them.
  """
  use FireflyWeb.Admin.Logged, as: "theme"

  def index(_),
    do: [name: nil, component: nil, user_selectable: nil, version: nil, updated_at: nil]

  def form_fields(_), do: [name: nil, description: %{type: :textarea}, user_selectable: nil]
  def search_fields(_), do: [:name]
  def default_actions(_), do: [:edit]
end
