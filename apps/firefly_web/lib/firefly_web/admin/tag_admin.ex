defmodule FireflyWeb.Admin.TagAdmin do
  @moduledoc "Tags in the database admin."
  use FireflyWeb.Admin.Logged, as: "tag"

  def index(_), do: [name: nil, group_id: nil, synonym_of_id: nil, inserted_at: nil]
  def form_fields(_), do: [name: nil]
  def search_fields(_), do: [:name]
end
