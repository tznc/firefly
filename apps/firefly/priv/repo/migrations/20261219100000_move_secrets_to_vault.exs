defmodule Firefly.Repo.Migrations.MoveSecretsToVault do
  use Ecto.Migration

  require Logger

  # Secrets move into Firefly.Vault, encrypted at rest with FIREFLY_VAULT_KEY:
  # AI providers' API keys (until now encrypted with FIREFLY_AI_ENCRYPTION_KEY,
  # or the secret key base, in their own format) and the secrets stored in
  # plaintext: authenticator (TOTP) secrets, plugins', webhooks' and
  # DiscourseConnect clients' secrets, push subscriptions' auth secrets and
  # secret site settings (now in `secret_value`). Every column becomes bytea.
  #
  # Down decrypts them back to how they were (AI keys in the old format).
  # Either way needs the vault key whenever there is something to convert.

  @plaintext [
    {"plugins", "secret", "varchar(255)"},
    {"webhooks", "secret", "varchar(255)"},
    {"discourse_connect_clients", "secret", "varchar(255)"},
    {"push_subscriptions", "auth", "varchar(255)"}
  ]
  @secret_settings ["akismet_api_key"]

  # The old AI key format: <<1, nonce::12, tag::16, ciphertext>>, AES-256-GCM.
  @legacy_aad "firefly ai secret"

  def up do
    for {table, column, _type} <- @plaintext do
      execute(
        "ALTER TABLE #{table} ALTER COLUMN #{column} TYPE bytea USING convert_to(#{column}, 'UTF8')"
      )
    end

    alter table(:forums_site_settings) do
      add :secret_value, :binary
    end

    flush()
    start_vault!()

    for {table, column, _type} <- @plaintext ++ [{"user_totps", "secret", nil}] do
      rewrite(table, column, &Firefly.Vault.encrypt!/1)
    end

    key = legacy_key()

    rewrite("ai_providers", "api_key", fn value ->
      case legacy_decrypt(value, key) do
        nil ->
          Logger.warning("An AI provider's API key couldn't be read with the old key: cleared")
          nil

        plaintext ->
          Firefly.Vault.encrypt!(plaintext)
      end
    end)

    %{rows: settings} =
      query!("SELECT id, value FROM forums_site_settings WHERE key = ANY($1)", [
        @secret_settings
      ])

    for [id, value] <- settings do
      query!(
        "UPDATE forums_site_settings SET secret_value = $2, value = '' WHERE id = $1",
        [id, Firefly.Vault.encrypt!(value)]
      )
    end
  end

  def down do
    start_vault!()

    for {table, column, _type} <- @plaintext ++ [{"user_totps", "secret", nil}] do
      rewrite(table, column, &Firefly.Vault.decrypt!/1)
    end

    key = legacy_key()
    rewrite("ai_providers", "api_key", &legacy_encrypt(Firefly.Vault.decrypt!(&1), key))

    %{rows: settings} =
      query!(
        "SELECT id, secret_value FROM forums_site_settings WHERE secret_value IS NOT NULL",
        []
      )

    for [id, value] <- settings do
      query!("UPDATE forums_site_settings SET value = $2 WHERE id = $1", [
        id,
        Firefly.Vault.decrypt!(value)
      ])
    end

    alter table(:forums_site_settings) do
      remove :secret_value
    end

    for {table, column, type} <- @plaintext do
      execute(
        "ALTER TABLE #{table} ALTER COLUMN #{column} TYPE #{type} USING convert_from(#{column}, 'UTF8')"
      )
    end
  end

  # Unlogged: the parameters are secrets.
  defp query!(sql, params), do: repo().query!(sql, params, log: false)

  # Rewrites every non-null value of the column with `fun`.
  defp rewrite(table, column, fun) do
    %{rows: rows} =
      query!("SELECT id, #{column} FROM #{table} WHERE #{column} IS NOT NULL", [])

    for [id, value] <- rows do
      query!("UPDATE #{table} SET #{column} = $2 WHERE id = $1", [id, fun.(value)])
    end
  end

  # The vault, started here when the application isn't (as under `mix
  # ecto.migrate` and `bin/migrate`). Without a key, only a database with no
  # secrets to convert can be migrated.
  defp start_vault! do
    keys = Application.get_env(:firefly, Firefly.Vault, [])[:keys] || []

    if keys == [] and secrets?() do
      raise """
      This migration encrypts the database's secrets with the vault key, and none is set.
      Set FIREFLY_VAULT_KEY to a base64-encoded 32-byte key (openssl rand -base64 32), keep
      it safe, and run the migration again. See "Encryption at rest" in the README.
      """
    end

    if Process.whereis(Firefly.Vault) == nil do
      {:ok, _pid} = Firefly.Vault.start_link(check_data: false)
    end
  end

  defp secrets? do
    Enum.any?(
      [{"user_totps", "secret"}, {"ai_providers", "api_key"}] ++
        for({table, column, _type} <- @plaintext, do: {table, column}),
      fn {table, column} ->
        %{rows: [[exists]]} =
          query!("SELECT EXISTS (SELECT 1 FROM #{table} WHERE #{column} IS NOT NULL)", [])

        exists
      end
    ) or
      match?(
        %{rows: [[true]]},
        query!(
          "SELECT EXISTS (SELECT 1 FROM forums_site_settings WHERE key = ANY($1))",
          [@secret_settings]
        )
      )
  end

  # The old AI key: FIREFLY_AI_ENCRYPTION_KEY, else the secret key base,
  # stretched as Firefly.AI.Encrypted did.
  defp legacy_key do
    case Application.get_env(:firefly, :legacy_ai_secret) do
      nil -> nil
      secret -> Plug.Crypto.KeyGenerator.generate(secret, "firefly ai secrets", length: 32)
    end
  end

  defp legacy_decrypt(<<1, nonce::binary-12, tag::binary-16, ciphertext::binary>>, key)
       when is_binary(key) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           @legacy_aad,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> plaintext
      :error -> nil
    end
  end

  defp legacy_decrypt(_value, _key), do: nil

  defp legacy_encrypt(_plaintext, nil),
    do: raise("set FIREFLY_AI_ENCRYPTION_KEY or FIREFLY_SECRET_KEY_BASE to roll back")

  defp legacy_encrypt(plaintext, key) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, @legacy_aad, true)

    <<1, nonce::binary-12, tag::binary-16, ciphertext::binary>>
  end
end
