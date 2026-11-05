defmodule Firefly.VaultTest do
  # Restarts the application's vault with other keys.
  use Firefly.DataCase, async: false

  import ExUnit.CaptureLog
  import Firefly.Fixtures

  alias Firefly.{Repo, Vault, Webhooks}
  alias Firefly.Accounts.TwoFactor.Totp

  @schemas_with_secrets [
    Firefly.AI.ProviderConfig,
    Firefly.Accounts.Auth.DiscourseConnectClient,
    Firefly.SiteSettings.SiteSetting,
    Firefly.Plugins.InstalledPlugin,
    Firefly.Notifications.WebPush.Subscription,
    Totp,
    Firefly.Webhooks.Webhook
  ]

  defp restart_vault(config) do
    original = Application.fetch_env!(:firefly, Vault)

    on_exit(fn ->
      Application.put_env(:firefly, Vault, original)
      :ok = Supervisor.terminate_child(Firefly.Supervisor, Vault)
      {:ok, _pid} = Supervisor.restart_child(Firefly.Supervisor, Vault)
    end)

    Application.put_env(:firefly, Vault, Keyword.merge(original, config))
    :ok = Supervisor.terminate_child(Firefly.Supervisor, Vault)
    Supervisor.restart_child(Firefly.Supervisor, Vault)
  end

  defp current_key, do: hd(Application.fetch_env!(:firefly, Vault)[:keys])

  defp stored_secret(totp_id) do
    %{rows: [[stored]]} = Repo.query!("SELECT secret FROM user_totps WHERE id = $1", [totp_id])
    stored
  end

  defp insert_totp(secret \\ "totp secret") do
    Repo.insert!(%Totp{user_id: user_fixture().id, secret: secret})
  end

  test "values round-trip, and are stored as ciphertext tagged with the key" do
    totp = insert_totp(<<0, 1, 2, 255>>)
    stored = stored_secret(totp.id)

    refute stored =~ <<0, 1, 2, 255>>
    assert String.starts_with?(stored, <<1, 13>> <> Vault.tag(current_key()))
    assert Repo.get!(Totp, totp.id).secret == <<0, 1, 2, 255>>
    # A fresh IV per value: the same secret encrypts differently each time.
    assert Vault.encrypt!("x") != Vault.encrypt!("x")
  end

  test "a tampered value doesn't decrypt" do
    <<head::binary-30, byte, rest::binary>> = Vault.encrypt!("secret value")
    assert {:error, _} = Vault.decrypt(head <> <<Bitwise.bxor(byte, 1)>> <> rest)
  end

  test "rotating re-encrypts old values with the new key, and old keys keep reading" do
    old = current_key()
    totp = insert_totp()
    new = :crypto.strong_rand_bytes(32)

    {:ok, _} = restart_vault(keys: [new, old])
    assert Repo.get!(Totp, totp.id).secret == "totp secret"
    assert String.starts_with?(stored_secret(totp.id), <<1, 13>> <> Vault.tag(old))

    capture_log(fn -> assert %{{"user_totps", "secret"} => 1} = Vault.rotate() end)
    assert String.starts_with?(stored_secret(totp.id), <<1, 13>> <> Vault.tag(new))
    # Nothing left to do the second time.
    assert %{{"user_totps", "secret"} => 0} = Vault.rotate()

    {:ok, _} = restart_vault(keys: [new])
    assert Repo.get!(Totp, totp.id).secret == "totp secret"
  end

  test "keys come from base64 of 32 bytes" do
    key = :crypto.strong_rand_bytes(32)
    assert Vault.decode_key!(" " <> Base.encode64(key) <> "\n") == key
    assert_raise ArgumentError, fn -> Vault.decode_key!(Base.encode64("short")) end
    assert_raise ArgumentError, fn -> Vault.ciphers(["short"]) end
  end

  test "without a key, writing a secret raises, and a database holding secrets is refused" do
    totp = insert_totp()
    assert_raise Vault.KeyMissing, &Vault.require_key!/0

    {:ok, _} = restart_vault(keys: [], check_data: false)
    assert_raise Vault.KeyMissing, fn -> Vault.encrypt("anything") end
    Repo.delete!(totp)
  end

  test "a database without secrets needs no key" do
    assert Vault.require_key!() == :ok
  end

  test "encrypts with AES-GCM only, and no field uses Cloak's PBKDF2 type" do
    # The audit ignores advisories against Cloak's AES-CTR cipher and
    # cloak_ecto's PBKDF2 type (see mix.exs): neither may be used.
    {:ok, config} = Cloak.Vault.read_config(:"Elixir.Firefly.Vault.Config")
    assert Enum.all?(config[:ciphers], &match?({_label, {Cloak.Ciphers.AES.GCM, _opts}}, &1))

    {:ok, modules} = :application.get_key(:firefly, :modules)

    for module <- modules,
        Code.ensure_loaded?(module),
        function_exported?(module, :__schema__, 1),
        field <- module.__schema__(:fields) do
      refute module.__schema__(:type, field) == Cloak.Ecto.PBKDF2
    end
  end

  test "every encrypted field is listed in the vault's columns, and redacted" do
    {:ok, modules} = :application.get_key(:firefly, :modules)

    fields =
      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__schema__, 1),
          field <- module.__schema__(:fields),
          module.__schema__(:type, field) == Firefly.Encrypted.Binary do
        assert field in module.__schema__(:redact_fields), "#{inspect(module)}.#{field}"
        {module.__schema__(:source), to_string(field)}
      end

    assert Enum.sort(fields) == Enum.sort(Vault.columns())

    assert Enum.sort(for m <- @schemas_with_secrets, do: m.__schema__(:source)) ==
             Enum.sort(for {table, _column} <- Vault.columns(), do: table)
  end

  test "secrets are never logged or shown by the schemas" do
    {:ok, hook} =
      Webhooks.create(
        %{
          "payload_url" => "https://example.com/hook",
          "wildcard" => "true",
          "secret" => "very-secret-value"
        },
        admin_fixture()
      )

    refute inspect(hook) =~ "very-secret-value"
    refute inspect(Repo.all(Firefly.Moderation.StaffAction)) =~ "very-secret-value"
    refute inspect(insert_totp("totp-plaintext")) =~ "totp-plaintext"
  end
end
