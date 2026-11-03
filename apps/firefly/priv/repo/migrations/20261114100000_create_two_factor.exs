defmodule Firefly.Repo.Migrations.CreateTwoFactor do
  use Ecto.Migration

  # Second factors (see Firefly.TwoFactor): an authenticator app's TOTP
  # secret, single-use backup codes (hashed), and WebAuthn credentials
  # (security keys).
  def change do
    create table(:user_totps) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :secret, :binary, null: false
      # The last code's time: a code can't be used twice.
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_totps, [:user_id])

    create table(:user_backup_codes) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :code_hash, :string, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_backup_codes, [:user_id])

    create table(:webauthn_credentials) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :name, :string, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])
  end
end
