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

  test "keys are 32 bytes, and the vault doesn't start without one" do
    assert_raise ArgumentError, fn -> Vault.ciphers(["short"]) end
    assert_raise ArgumentError, ~r/FIREFLY_VAULT_KEY/, fn -> Vault.init(keys: []) end
  end

  test "production requires FIREFLY_VAULT_KEY, base64 of 32 bytes" do
    vars = %{
      "FIREFLY_DATABASE_URL" => "ecto://u:p@db/firefly",
      "FIREFLY_SECRET_KEY_BASE" => String.duplicate("k", 64),
      "FIREFLY_MAIL_ADAPTER" => "local",
      "FIREFLY_VAULT_KEY" => nil,
      "FIREFLY_VAULT_RETIRED_KEYS" => nil
    }

    saved = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)
    on_exit(fn -> put_env(saved) end)
    put_env(vars)
    runtime = Path.expand("../../../config/runtime.exs", __DIR__)

    assert_raise RuntimeError, ~r/FIREFLY_VAULT_KEY is missing/, fn ->
      Config.Reader.read!(runtime, env: :prod)
    end

    System.put_env("FIREFLY_VAULT_KEY", Base.encode64("short"))
    assert_raise RuntimeError, ~r/32 bytes/, fn -> Config.Reader.read!(runtime, env: :prod) end

    [new, old] = for _ <- 1..2, do: :crypto.strong_rand_bytes(32)
    System.put_env("FIREFLY_VAULT_KEY", Base.encode64(new))
    System.put_env("FIREFLY_VAULT_RETIRED_KEYS", Base.encode64(old))
    assert Config.Reader.read!(runtime, env: :prod)[:firefly][Vault][:keys] == [new, old]
  end

  defp put_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  # mix.exs acknowledges two advisories, for parts of Cloak Firefly must
  # never use: CVE-2026-95105 (the AES-CTR cipher, Cloak.Ciphers.AES.CTR)
  # and CVE-2026-94206 (cloak_ecto's PBKDF2 type, Cloak.Ecto.PBKDF2). These
  # tests fail as soon as either comes into use: in the code of every app
  # loaded (the domain, here) and in every app's source and the config.
  @apps [:firefly, :firefly_web, :firefly_plugins, :firefly_import]
  @sources Path.wildcard(Path.expand("../../*/lib/**/*.ex", __DIR__)) ++
             Path.wildcard(Path.expand("../../../config/*.exs", __DIR__))

  test "the vault only ever encrypts with AES-GCM, never AES-CTR (CVE-2026-95105)" do
    {:ok, config} = Cloak.Vault.read_config(:"Elixir.Firefly.Vault.Config")
    assert [_ | _] = config[:ciphers]
    assert Enum.all?(config[:ciphers], &match?({_label, {Cloak.Ciphers.AES.GCM, _opts}}, &1))

    # Whatever the keys: rotation sets are GCM too, and configured ciphers
    # are replaced by ones built from the keys.
    keys = for _ <- 1..3, do: :crypto.strong_rand_bytes(32)
    assert Enum.all?(Vault.ciphers(keys), &match?({_, {Cloak.Ciphers.AES.GCM, _}}, &1))

    ctr = [ciphers: [default: {Cloak.Ciphers.AES.CTR, tag: "CTR", key: hd(keys)}]]
    {:ok, built} = Vault.init(ctr ++ [keys: keys])
    refute inspect(built[:ciphers]) =~ "CTR"

    assert sources_mentioning("AES.CTR") == []
  end

  test "no schema uses cloak_ecto's PBKDF2 type (CVE-2026-94206)" do
    for app <- @apps,
        {:ok, modules} <- [:application.get_key(app, :modules)],
        module <- modules,
        Code.ensure_loaded?(module) do
      behaviours = Keyword.get_values(module.module_info(:attributes), :behaviour)
      refute Cloak.Ecto.PBKDF2 in List.flatten(behaviours), "#{inspect(module)} is a PBKDF2 type"

      if function_exported?(module, :__schema__, 1) do
        for field <- module.__schema__(:fields) do
          refute module.__schema__(:type, field) == Cloak.Ecto.PBKDF2,
                 "#{inspect(module)}.#{field}"
        end
      end
    end

    assert sources_mentioning("PBKDF2") == []
  end

  # Every app's source is read, whichever app's tests run.
  defp sources_mentioning(text) do
    assert Enum.any?(@sources, &String.contains?(&1, "firefly_web/lib/"))
    for path <- @sources, File.read!(path) =~ text, do: Path.relative_to_cwd(path)
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
