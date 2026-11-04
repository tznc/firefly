defmodule FireflyWeb.Admin.BadgeAdmin do
  @moduledoc "Badges in the database admin."
  use FireflyWeb.Admin.Logged, as: "badge"

  def index(_), do: [name: nil, badge_type: nil, enabled: nil, system: nil, inserted_at: nil]

  def form_fields(_) do
    [
      name: nil,
      description: %{type: :textarea},
      icon: nil,
      badge_type: nil,
      grouping: nil,
      enabled: nil,
      allow_title: nil,
      multiple_grant: nil,
      listable: nil
    ]
  end

  def search_fields(_), do: [:name]
end
