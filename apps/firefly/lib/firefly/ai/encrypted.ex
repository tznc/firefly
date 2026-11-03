defmodule Firefly.AI.Encrypted do
  @moduledoc """
  An Ecto type for secrets kept encrypted at rest (AI providers' API
  keys): AES-256-GCM, with a fresh nonce per value, stored as
  `<<1, nonce::12 bytes, tag::16 bytes, ciphertext>>`.

  The key comes from `FIREFLY_AI_ENCRYPTION_KEY` (`config :firefly,
  Firefly.AI, encryption_key:`) when it's set, else from the endpoint's
  secret key base, stretched with PBKDF2 either way. Changing it makes the
  stored keys unreadable: they load as nil and admins enter them again.
  """

  use Ecto.Type

  @version 1
  @aad "firefly ai secret"

  @impl true
  def type, do: :binary

  @impl true
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, encrypt(value)}
  def dump(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}
  def load(value) when is_binary(value), do: {:ok, decrypt(value)}

  @doc "Encrypts `plaintext`."
  def encrypt(plaintext) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, plaintext, @aad, true)

    <<@version, nonce::binary-12, tag::binary-16, ciphertext::binary>>
  end

  @doc "Decrypts what `encrypt/1` made: the plaintext, or nil when it can't (another key)."
  def decrypt(<<@version, nonce::binary-12, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> plaintext
      :error -> nil
    end
  end

  def decrypt(_value), do: nil

  # Derived once per secret: PBKDF2 is slow on purpose.
  defp key do
    secret =
      Application.get_env(:firefly, Firefly.AI, [])[:encryption_key] ||
        Firefly.Endpoint.secret_key_base()

    cache_key = {__MODULE__, :crypto.hash(:sha256, secret)}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        key = Plug.Crypto.KeyGenerator.generate(secret, "firefly ai secrets", length: 32)
        :persistent_term.put(cache_key, key)
        key

      key ->
        key
    end
  end
end
