defmodule FirestormWeb.Repo.Migrations.CreateDiscourseConnectNonces do
  use Ecto.Migration

  # The nonces of DiscourseConnect logins in progress: each is accepted once,
  # within its expiry (see FirestormWeb.Auth.DiscourseConnect).
  def change do
    create table(:discourse_connect_nonces) do
      add :nonce, :string, null: false
      add :expires_at, :utc_datetime, null: false
    end

    create unique_index(:discourse_connect_nonces, [:nonce])
    create index(:discourse_connect_nonces, [:expires_at])
  end
end
