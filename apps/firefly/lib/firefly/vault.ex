defmodule Firefly.Vault do
  @moduledoc """
  Encryption at rest for secrets kept in the database: AI providers' API
  keys, authenticator (TOTP) secrets, secret site settings, plugins' and
  webhooks' signing secrets, DiscourseConnect clients' secrets and browser
  push subscriptions' auth secrets (`columns/0` lists them). Schemas mark
  such a field `Firefly.Encrypted.Binary`; it's encrypted when written and
  decrypted when loaded, so the rest of the code sees plaintext.

  It's a [Cloak](https://hexdocs.pm/cloak) vault: AES-256-GCM with a random
  12-byte IV per value. Each value starts with its key's tag, so values
  written under an older key stay readable while a new key encrypts.

  ## Keys

  `config :firefly, Firefly.Vault, keys: [current | retired]`, 32-byte
  keys, from `FIREFLY_VAULT_KEY` (base64) and `FIREFLY_VAULT_RETIRED_KEYS`
  (base64, comma-separated) in production. The first key encrypts; every
  key decrypts. A key's tag is a fingerprint of it (`tag/1`), so keys need
  no names and their order in the environment doesn't matter.

  Rotating: make a new key (`openssl rand -base64 32`), set it as
  `FIREFLY_VAULT_KEY` and move the old one to `FIREFLY_VAULT_RETIRED_KEYS`,
  restart every node, run `rotate/0` (`mix firefly.vault.rotate`, or
  `bin/firefly eval Firefly.Release.rotate_vault` in a release), then drop
  the retired key.

  Production requires `FIREFLY_VAULT_KEY`; development and tests use fixed
  keys (`config/dev.exs`, `config/test.exs`).
  """

  use Cloak.Vault, otp_app: :firefly

  import Ecto.Query

  alias Firefly.Repo

  require Logger

  # Every encrypted column, `{table, column}`; each table has an `id` key.
  # A test checks this matches the schemas' `Firefly.Encrypted.Binary` fields.
  @columns [
    {"ai_providers", "api_key"},
    {"discourse_connect_clients", "secret"},
    {"forums_site_settings", "secret_value"},
    {"plugins", "secret"},
    {"push_subscriptions", "auth"},
    {"user_totps", "secret"},
    {"webhooks", "secret"}
  ]

  @rotate_batch 500

  @impl GenServer
  def init(config) do
    case Keyword.get(config, :keys, []) do
      [] -> raise ArgumentError, "no vault key: set FIREFLY_VAULT_KEY (see Firefly.Vault)"
      keys -> {:ok, Keyword.put(config, :ciphers, ciphers(keys))}
    end
  end

  @doc "The Cloak ciphers for `keys`, the first one encrypting."
  @spec ciphers([binary]) :: keyword
  def ciphers(keys) do
    keys
    |> Enum.with_index()
    |> Enum.map(fn {key, index} ->
      if byte_size(key) != 32, do: raise(ArgumentError, "vault keys must be 32 bytes")

      label = if index == 0, do: :current, else: :"retired_#{index}"
      {label, {Cloak.Ciphers.AES.GCM, tag: tag(key), key: key, iv_length: 12}}
    end)
  end

  @doc """
  The tag values encrypted with `key` start with: `"FFV1."` and the first
  eight hex digits of the key's SHA-256.
  """
  @spec tag(binary) :: String.t()
  def tag(key),
    do: "FFV1." <> binary_part(Base.encode16(:crypto.hash(:sha256, key), case: :lower), 0, 8)

  @doc "The encrypted columns, `{table, column}`."
  @spec columns() :: [{String.t(), String.t()}]
  def columns, do: @columns

  # Cloak's AES-GCM returns `{:ok, :error}` when the tag doesn't verify (a
  # tampered or corrupt value): that's an error, never a plaintext.
  @impl Cloak.Vault
  def decrypt(ciphertext) do
    case super(ciphertext) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      {:ok, _not_plaintext} -> {:error, %ArgumentError{message: "the value doesn't verify"}}
      error -> error
    end
  end

  @doc """
  Re-encrypts every value not encrypted with the current key, in batches.
  Returns how many values were rewritten per column.
  """
  @spec rotate() :: %{{String.t(), String.t()} => non_neg_integer}
  def rotate do
    {:ok, config} = Cloak.Vault.read_config(:"#{__MODULE__}.Config")
    [{:current, {_cipher, opts}} | _retired] = config[:ciphers]
    prefix = tag_prefix(opts[:tag])

    Map.new(@columns, fn {table, column} = key ->
      count = rotate_column(table, String.to_atom(column), prefix, 0, 0)
      if count > 0, do: Logger.info("Re-encrypted #{count} values in #{table}.#{column}")
      {key, count}
    end)
  end

  defp rotate_column(table, column, prefix, after_id, count) do
    rows =
      Repo.all(
        from(r in table,
          where: r.id > ^after_id and not is_nil(field(r, ^column)),
          order_by: r.id,
          limit: @rotate_batch,
          select: {r.id, field(r, ^column)}
        )
      )

    stale = for {id, value} <- rows, not String.starts_with?(value, prefix), do: {id, value}

    for {id, value} <- stale do
      fresh = encrypt!(decrypt!(value))
      Repo.update_all(from(r in table, where: r.id == ^id), set: [{column, fresh}])
    end

    case rows do
      [] -> count
      _ -> rotate_column(table, column, prefix, elem(List.last(rows), 0), count + length(stale))
    end
  end

  # How Cloak encodes a tag at the start of a value (type, length, tag).
  defp tag_prefix(tag), do: <<1, byte_size(tag)>> <> tag
end
