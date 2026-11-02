defmodule Firefly.WebPush.VAPIDTest do
  use ExUnit.Case, async: true

  alias Firefly.WebPush.{Encryption, VAPID}

  test "signs an ES256 JWT for the push service's origin" do
    {public, private} = VAPID.generate_keys()
    assert byte_size(Encryption.decode64(public)) == 65
    assert byte_size(Encryption.decode64(private)) == 32

    header =
      VAPID.authorization(
        "https://push.example.com:8443/send/abc",
        "mailto:admin@example.com",
        public,
        private,
        1_000
      )

    assert "vapid t=" <> rest = header
    [token, "k=" <> ^public] = String.split(rest, ", ")
    [h, c, s] = String.split(token, ".")

    assert Jason.decode!(Encryption.decode64(h)) == %{"typ" => "JWT", "alg" => "ES256"}

    assert Jason.decode!(Encryption.decode64(c)) == %{
             "aud" => "https://push.example.com:8443",
             "exp" => 1_000 + 12 * 3600,
             "sub" => "mailto:admin@example.com"
           }

    <<r::unsigned-big-256, s_value::unsigned-big-256>> = Encryption.decode64(s)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s_value})

    assert :crypto.verify(:ecdsa, :sha256, h <> "." <> c, der, [
             Encryption.decode64(public),
             :prime256v1
           ])
  end
end
