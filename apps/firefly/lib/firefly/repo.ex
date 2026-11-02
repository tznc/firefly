defmodule Firefly.Repo do
  use Ecto.Repo, otp_app: :firefly, adapter: Ecto.Adapters.Postgres
  use Scrivener, page_size: 10
end
