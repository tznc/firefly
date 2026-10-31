defmodule FirestormWeb.Repo do
  use Ecto.Repo, otp_app: :firestorm_web, adapter: Ecto.Adapters.Postgres
  use Scrivener, page_size: 10
end
