defmodule Firefly.WebPush.VAPID do
  @moduledoc """
  Voluntary application server identification for Web Push (RFC 8292):
  the `Authorization: vapid t=<JWT>, k=<public key>` header, a JWT signed
  with ES256 by the site's VAPID key pair, for the push service's origin.
  Keys are base64url: the public key an uncompressed P-256 point (65
  bytes), the private key its scalar (32 bytes), as `generate_keys/0`
  makes them.
  """

  alias Firefly.WebPush.Encryption

  # How long a token is valid (at most 24 hours, RFC 8292).
  @lifetime 12 * 3600

  @doc "A new key pair, base64url: `{public, private}`."
  def generate_keys do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    {encode64(public), encode64(private)}
  end

  @doc """
  The `Authorization` header for a push to `endpoint`, signed with the
  `public` and `private` keys, naming `subject` (a `mailto:` or `https:`
  URL) as the contact.
  """
  def authorization(endpoint, subject, public, private, now \\ System.os_time(:second)) do
    "vapid t=#{token(endpoint, subject, private, now)}, k=#{public}"
  end

  defp token(endpoint, subject, private, now) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    default_port? = {scheme, port} in [{"https", 443}, {"http", 80}]
    audience = "#{scheme}://#{host}" <> if(default_port?, do: "", else: ":#{port}")

    header = encode64(Jason.encode!(%{typ: "JWT", alg: "ES256"}))
    claims = encode64(Jason.encode!(%{aud: audience, exp: now + @lifetime, sub: subject}))
    input = header <> "." <> claims

    der = :crypto.sign(:ecdsa, :sha256, input, [Encryption.decode64(private), :prime256v1])
    input <> "." <> encode64(raw_signature(der))
  end

  # JWS wants ECDSA signatures as r || s (32 bytes each), not DER.
  defp raw_signature(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::unsigned-big-256, s::unsigned-big-256>>
  end

  defp encode64(binary), do: Base.url_encode64(binary, padding: false)
end
