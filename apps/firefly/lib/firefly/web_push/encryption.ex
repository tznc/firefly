defmodule Firefly.WebPush.Encryption do
  @moduledoc """
  Message encryption for Web Push (RFC 8291), in the `aes128gcm` content
  coding (RFC 8188): one record, keyed from an ECDH agreement between a
  fresh application server key pair and the browser's subscription key
  (`p256dh`), mixed with the subscription's `auth` secret.
  """

  # The record size announced in the header; the payload fits one record.
  @record_size 4096

  @doc """
  Encrypts `plaintext` for a subscription's `p256dh` public key and `auth`
  secret (both base64url, as browsers give them). Returns the request body:
  the header (salt, record size, our public key) and the ciphertext.

  `opts` fix the `:salt` and `:keys` (`{public, private}`) instead of
  random ones, for test vectors.
  """
  def encrypt(plaintext, p256dh, auth, opts \\ []) when is_binary(plaintext) do
    ua_public = decode64(p256dh)
    auth_secret = decode64(auth)
    salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

    {as_public, as_private} =
      Keyword.get_lazy(opts, :keys, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

    ecdh_secret = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    %{key: key, nonce: nonce} = keys(ecdh_secret, auth_secret, ua_public, as_public, salt)

    # The last (and only) record ends with the 0x02 delimiter.
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, plaintext <> <<2>>, <<>>, true)

    salt <>
      <<@record_size::unsigned-big-32, byte_size(as_public)::8>> <>
      as_public <> ciphertext <> tag
  end

  @doc "The content encryption key and nonce (RFC 8291, section 3.4)."
  def keys(ecdh_secret, auth_secret, ua_public, as_public, salt) do
    prk_key = hmac(auth_secret, ecdh_secret)
    ikm = hmac(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)
    prk = hmac(salt, ikm)

    %{
      key: binary_part(hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16),
      nonce: binary_part(hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)
    }
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  @doc "Decodes base64url, padded or not."
  def decode64(text),
    do: text |> String.trim_trailing("=") |> Base.url_decode64!(padding: false)
end
