defmodule FireflyWeb.Admin.PostAdmin do
  @moduledoc """
  Posts in the database admin. Like threads, they're only edited here.
  """
  use FireflyWeb.Admin.Logged, as: "post"

  def index(_) do
    [
      body: %{value: &String.slice(&1.body || "", 0..79)},
      thread_id: nil,
      user_id: nil,
      inserted_at: nil
    ]
  end

  def form_fields(_) do
    [
      body: %{type: :textarea},
      thread_id: %{update: :readonly},
      user_id: %{update: :readonly}
    ]
  end

  def search_fields(_), do: [:body]
  def default_actions(_), do: [:edit]
end
