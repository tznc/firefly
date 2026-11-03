defmodule Firefly.Repo.Migrations.AddPasskeysAndMagicLinks do
  use Ecto.Migration

  # Passkeys are discoverable WebAuthn credentials that log in on their own
  # (see Firefly.Passkeys); magic links are emailed one-time login
  # links, stored only as hashes (see Firefly.MagicLinks).
  def change do
    alter table(:webauthn_credentials) do
      add :passkey, :boolean, null: false, default: false
    end

    create table(:magic_link_tokens) do
      # Nil for a link that signs up a new account (the email's).
      add :user_id, references(:forums_users, on_delete: :delete_all)
      add :email, :string, null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:magic_link_tokens, [:token_hash])
    create index(:magic_link_tokens, [:user_id])
    create index(:magic_link_tokens, [:expires_at])
  end
end
