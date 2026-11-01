defmodule FirestormWeb.Admin.NotificationAdmin do
  @moduledoc "Kaffy admin for notifications."
  def index(_), do: [subject: nil, user_id: nil, inserted_at: nil]
  def form_fields(_), do: [subject: nil, body: %{type: :textarea}, url: nil, user_id: nil]
  def search_fields(_), do: [:subject]
end
