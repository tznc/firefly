defmodule FirestormWeb.Admin.ThreadAdmin do
  @moduledoc "Kaffy admin for threads. Slugs are generated from the title."
  use FirestormWeb.Admin.Logged, as: "thread"

  def index(_), do: [title: nil, category_id: nil, inserted_at: nil]
  def form_fields(_), do: [title: nil, category_id: nil]
  def search_fields(_), do: [:title]
end
