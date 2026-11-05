defmodule Firefly.VaultMigrationTest do
  @moduledoc """
  The migration that moved the database's secrets into `Firefly.Vault`,
  run down and up on real rows inside the test's transaction (PostgreSQL
  DDL is transactional, so the sandbox rolls it all back).
  """
  use Firefly.DataCase, async: false

  @moduletag :capture_log

  import Firefly.Fixtures

  alias Firefly.{AI, Repo, SiteSettings, Vault}
  alias Firefly.Accounts.TwoFactor.Totp

  @version 20_261_219_100_000
  @path "../priv/repo/migrations/20261219100000_move_secrets_to_vault.exs"

  @migration Firefly.Repo.Migrations.MoveSecretsToVault

  # Loaded already when `mix test` just ran it.
  setup_all do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(Path.expand(@path, __DIR__))
    %{migration: @migration}
  end

  # The migration's commands, run in this process (the migrator's own
  # connections would escape the sandbox).
  defp migrate(migration, direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      migration,
      :forward,
      direction,
      direction,
      log: false
    )
  end

  defp now, do: NaiveDateTime.utc_now()

  # Insert rows as the schema before the vault stored them.
  defp insert_old_rows(user) do
    Repo.query!(
      "INSERT INTO user_totps (user_id, secret, inserted_at, updated_at) VALUES ($1, $2, $3, $3)",
      [user.id, <<1, 2, 3, 250>>, now()]
    )

    Repo.query!(
      "INSERT INTO webhooks (payload_url, secret, inserted_at, updated_at) VALUES ('https://example.com/hook', 'hook-secret', $1, $1)",
      [now()]
    )

    Repo.query!(
      "INSERT INTO plugins (plugin_id, source, version, secret, inserted_at, updated_at) VALUES ('p', 'builtin', '1', 'plugin-secret', $1, $1)",
      [now()]
    )

    Repo.query!(
      "INSERT INTO discourse_connect_clients (name, secret, inserted_at, updated_at) VALUES ('blog', 'dc-secret', $1, $1)",
      [now()]
    )

    Repo.query!(
      "INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, inserted_at, updated_at) VALUES ($1, 'https://push.example.com/1', 'p256dh', 'push-auth', $2, $2)",
      [user.id, now()]
    )

    Repo.query!(
      "INSERT INTO ai_providers (name, adapter, base_url, model, max_tokens, timeout_seconds, api_key, inserted_at, updated_at) VALUES ('A', 'openai', 'https://api.openai.com/v1', 'm', 10, 10, $1, $2, $2)",
      [legacy_encrypt("sk-legacy"), now()]
    )

    Repo.query!(
      "INSERT INTO ai_providers (name, adapter, base_url, model, max_tokens, timeout_seconds, api_key, inserted_at, updated_at) VALUES ('B', 'openai', 'https://api.openai.com/v1', 'm', 10, 10, $1, $2, $2)",
      [<<1>> <> :crypto.strong_rand_bytes(40), now()]
    )

    Repo.query!(
      "INSERT INTO forums_site_settings (key, value, inserted_at, updated_at) VALUES ('akismet_api_key', 'akismet-secret', $1, $1), ('title', 'Old title', $1, $1)",
      [now()]
    )
  end

  # Firefly.AI.Encrypted's format, keyed by the secret key base.
  defp legacy_encrypt(plaintext) do
    secret = Application.fetch_env!(:firefly, :legacy_ai_secret)
    key = Plug.Crypto.KeyGenerator.generate(secret, "firefly ai secrets", length: 32)
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, "firefly ai secret", true)

    <<1, nonce::binary-12, tag::binary-16, ciphertext::binary>>
  end

  defp raw(sql), do: Repo.query!(sql).rows

  test "encrypts old secrets on the way up, and puts them back on the way down", %{
    migration: migration
  } do
    user = user_fixture()
    migrate(migration, :down)
    insert_old_rows(user)

    migrate(migration, :up)

    # Every value is now a vault ciphertext under the current key.
    for {table, column} <- Vault.columns(),
        [value] <- raw("SELECT #{column} FROM #{table} WHERE #{column} IS NOT NULL") do
      assert String.starts_with?(value, <<1, 13>> <> current_tag()), "#{table}.#{column}"
    end

    assert raw("SELECT value FROM forums_site_settings WHERE key = 'akismet_api_key'") == [[""]]
    assert raw("SELECT value FROM forums_site_settings WHERE key = 'title'") == [["Old title"]]

    # And the schemas read the plaintext back.
    assert Repo.get_by!(Totp, user_id: user.id).secret == <<1, 2, 3, 250>>
    assert Repo.one!(from(w in "webhooks", select: w.id)) |> webhook_secret() == "hook-secret"
    assert Firefly.Plugins.secret("p") == "plugin-secret"
    assert [%{api_key: "sk-legacy"}] = Enum.filter(AI.list_providers(), &(&1.name == "A"))
    # A key the old secret can't read is cleared, as it read as nil before.
    assert [%{api_key: nil}] = Enum.filter(AI.list_providers(), &(&1.name == "B"))
    SiteSettings.clear_cache()
    assert SiteSettings.get("akismet_api_key") == "akismet-secret"

    migrate(migration, :down)

    assert raw("SELECT secret FROM webhooks") == [["hook-secret"]]
    assert raw("SELECT secret FROM plugins") == [["plugin-secret"]]
    assert raw("SELECT secret FROM discourse_connect_clients") == [["dc-secret"]]
    assert raw("SELECT auth FROM push_subscriptions") == [["push-auth"]]
    assert raw("SELECT secret FROM user_totps") == [[<<1, 2, 3, 250>>]]

    assert raw("SELECT value FROM forums_site_settings WHERE key = 'akismet_api_key'") == [
             ["akismet-secret"]
           ]

    [[old_format]] = raw("SELECT api_key FROM ai_providers WHERE name = 'A'")
    assert <<1, _nonce::binary-12, _tag::binary-16, _ciphertext::binary>> = old_format
    refute old_format =~ "sk-legacy"

    # Up again: the rolled-back AI key is still readable with the old secret.
    migrate(migration, :up)
    assert [%{api_key: "sk-legacy"}] = Enum.filter(AI.list_providers(), &(&1.name == "A"))
  end

  test "refuses to run without a vault key when there are secrets to encrypt", %{
    migration: migration
  } do
    user = user_fixture()
    migrate(migration, :down)
    insert_old_rows(user)

    config = Application.fetch_env!(:firefly, Firefly.Vault)
    Application.put_env(:firefly, Firefly.Vault, Keyword.put(config, :keys, []))
    on_exit(fn -> Application.put_env(:firefly, Firefly.Vault, config) end)

    assert_raise RuntimeError, ~r/FIREFLY_VAULT_KEY/, fn -> migrate(migration, :up) end
  end

  defp webhook_secret(id), do: Repo.get!(Firefly.Webhooks.Webhook, id).secret

  defp current_tag do
    [key | _] = Application.fetch_env!(:firefly, Firefly.Vault)[:keys]
    Vault.tag(key)
  end
end
