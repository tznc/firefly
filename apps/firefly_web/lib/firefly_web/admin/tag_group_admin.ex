defmodule FireflyWeb.Admin.TagGroupAdmin do
  @moduledoc "Tag groups in the database admin."
  use FireflyWeb.Admin.Logged, as: "tag_group"

  def index(_), do: [name: nil, staff_only: nil, one_per_thread: nil, inserted_at: nil]
  def form_fields(_), do: [name: nil, staff_only: nil, one_per_thread: nil]
  def search_fields(_), do: [:name]
end
