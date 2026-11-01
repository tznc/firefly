defmodule FirestormWeb.Admin.PostAdmin do
  @moduledoc "Kaffy admin for posts."
  def index(_) do
    [
      body: %{value: &String.slice(&1.body || "", 0..79)},
      thread_id: nil,
      user_id: nil,
      inserted_at: nil
    ]
  end

  def form_fields(_), do: [body: %{type: :textarea}, thread_id: nil, user_id: nil]
  def search_fields(_), do: [:body]
end
