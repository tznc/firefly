defmodule FirestormWeb.WebPush.EncryptionTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.WebPush.Encryption

  # RFC 8291, Appendix A.
  @plaintext "When I grow up, I want to be a watermelon"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @ua_private "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @body "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  defp d(text), do: Encryption.decode64(text)

  test "matches the RFC 8291 test vector" do
    body =
      Encryption.encrypt(@plaintext, @ua_public, @auth,
        salt: d(@salt),
        keys: {d(@as_public), d(@as_private)}
      )

    assert Base.url_encode64(body, padding: false) == @body
  end

  test "derives the RFC's key and nonce" do
    secret = :crypto.compute_key(:ecdh, d(@as_public), d(@ua_private), :prime256v1)

    assert %{key: key, nonce: nonce} =
             Encryption.keys(secret, d(@auth), d(@ua_public), d(@as_public), d(@salt))

    assert Base.url_encode64(key, padding: false) == "oIhVW04MRdy2XN9CiKLxTg"
    assert Base.url_encode64(nonce, padding: false) == "4h_95klXJ5E_qnoN"
  end

  test "the browser can decrypt a message with fresh keys" do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    encode = &Base.url_encode64(&1, padding: false)

    body = Encryption.encrypt(~s({"title":"Hi"}), encode.(ua_public), encode.(auth))

    <<salt::binary-16, 4096::32, 65, as_public::binary-65, rest::binary>> = body
    secret = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    %{key: key, nonce: nonce} = Encryption.keys(secret, auth, ua_public, as_public, salt)
    <<ciphertext::binary-size(byte_size(rest) - 16), tag::binary-16>> = rest

    assert :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, ciphertext, <<>>, tag, false) ==
             ~s({"title":"Hi"}) <> <<2>>
  end
end
