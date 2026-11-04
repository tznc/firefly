defmodule FireflyWeb.Admin.EmailLogAdmin do
  @moduledoc "The email log in the database admin, to read."
  use FireflyWeb.Admin.Logged, as: "email_log"

  def index(_), do: [to: nil, subject: nil, template: nil, status: nil, inserted_at: nil]

  def form_fields(_),
    do: [to: nil, subject: nil, template: nil, status: nil, error: nil, user_id: nil]

  def search_fields(_), do: [:to, :subject]
  def default_actions(_), do: []
  def ordering(_), do: [desc: :id]
end
