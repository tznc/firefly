defmodule Firefly.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  # API keys (see Firefly.Accounts.ApiKeys): a member's own keys, and global
  # keys admins create (no user_id: they act as the user a request names).
  # Only a hash of each key is kept; the key itself is shown once.
  #
  # Every member's old `api_token` becomes a key with all the scopes, so
  # existing integrations keep working, and the plain-text column goes.
  def up do
    create table(:api_keys) do
      add :name, :string, null: false
      add :token_hash, :string, null: false
      # The key's first characters, to tell keys apart in lists.
      add :prefix, :string, null: false
      add :user_id, references(:forums_users, on_delete: :delete_all)
      add :created_by_id, references(:forums_users, on_delete: :nilify_all)
      add :scopes, {:array, :string}, null: false, default: []
      # Addresses or CIDR ranges the key may be used from (empty: anywhere).
      add :allowed_ips, {:array, :string}, null: false, default: []
      # Requests per minute (nil: the api_rate_limit site setting).
      add :rate_limit, :integer
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :last_used_ip, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:token_hash])
    create index(:api_keys, [:user_id])

    execute("""
    INSERT INTO api_keys (name, token_hash, prefix, user_id, scopes, inserted_at, updated_at)
    SELECT 'API token', encode(sha256(convert_to(api_token, 'UTF8')), 'hex'),
           left(api_token, 8), id, ARRAY['read', 'write', 'admin'], now(), now()
    FROM forums_users
    WHERE api_token IS NOT NULL AND deleted_at IS NULL AND plugin_bot IS NULL
    """)

    alter table(:forums_users) do
      remove :api_token
    end
  end

  # The keys' plain text is gone: members get new random tokens.
  def down do
    alter table(:forums_users) do
      add :api_token, :string
    end

    execute("UPDATE forums_users SET api_token = gen_random_uuid()::text")

    drop table(:api_keys)
  end
end
