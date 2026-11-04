defmodule FireflyWeb.Admin.ThreadAdmin do
  @moduledoc """
  Threads in the database admin. Starting and deleting threads stays with
  the forum, which keeps counts, search and notifications in step.
  """
  use FireflyWeb.Admin.Logged, as: "thread"

  def index(_), do: [title: nil, category_id: nil, inserted_at: nil]
  def form_fields(_), do: [title: nil, category_id: nil]
  def search_fields(_), do: [:title]
  def default_actions(_), do: [:edit]
end
