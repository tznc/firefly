defmodule Firefly.Repo.Migrations.CreateDiscourseConnectClients do
  use Ecto.Migration

  # Firefly as a DiscourseConnect provider (see
  # Firefly.Accounts.Auth.DiscourseConnectProvider): the sites allowed to log
  # people in through it, each with its own secret, and the nonces already
  # answered, so a signed request can't be answered twice.
  def change do
    create table(:discourse_connect_clients) do
      add :name, :string, null: false
      add :secret, :binary, null: false
      add :allowed_hosts, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create table(:discourse_connect_provider_nonces) do
      add :client_id, references(:discourse_connect_clients, on_delete: :delete_all), null: false
      add :nonce, :string, null: false
      add :expires_at, :utc_datetime, null: false
    end

    create unique_index(:discourse_connect_provider_nonces, [:client_id, :nonce])
    create index(:discourse_connect_provider_nonces, [:expires_at])
  end
end
