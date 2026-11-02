defmodule FirestormWeb.SoftAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator for tests: an ES256 key pair that
  answers registration and authentication challenges the way a browser and
  security key would (`none` attestation), as the base64url params
  `FirestormWeb.WebAuthn` reads.
  """

  alias FirestormWeb.WebAuthn

  defstruct [:id, :public, :private, :user_handle, count: 0]

  @doc "A new authenticator holding one credential (for `user_handle`, for passkeys)."
  def new(user_handle \\ nil) do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    %__MODULE__{
      id: :crypto.strong_rand_bytes(16),
      public: public,
      private: private,
      user_handle: user_handle
    }
  end

  @doc "Answers `navigator.credentials.create` for the challenge in `options` (a map with `:challenge`)."
  def register(%__MODULE__{} = key, options, opts \\ []) do
    <<4, x::binary-size(32), y::binary-size(32)>> = key.public
    cose = %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(x), -3 => bytes(y)}

    attested = <<0::128, byte_size(key.id)::16>> <> key.id <> CBOR.encode(cose)
    auth_data = auth_data(Keyword.get(opts, :flags, 0x45), key.count, opts) <> attested

    object =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth_data)})

    %{
      "attestation_object" => WebAuthn.encode(object),
      "client_data_json" => WebAuthn.encode(client_data("webauthn.create", options, opts))
    }
  end

  @doc """
  Answers `navigator.credentials.get` for `options` (a map with
  `:challenge`): returns the params and the authenticator with its counter
  moved on. `opts`: `:flags` (default user present and verified), `:count`,
  `:origin`, `:type`.
  """
  def assert(%__MODULE__{} = key, options, opts \\ []) do
    count = Keyword.get(opts, :count, key.count + 1)
    auth_data = auth_data(Keyword.get(opts, :flags, 0x05), count, opts)
    client_data = client_data(Keyword.get(opts, :type, "webauthn.get"), options, opts)

    signature =
      :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client_data), [
        key.private,
        :prime256v1
      ])

    params = %{
      "id" => WebAuthn.encode(key.id),
      "authenticator_data" => WebAuthn.encode(auth_data),
      "signature" => WebAuthn.encode(signature),
      "client_data_json" => WebAuthn.encode(client_data),
      "user_handle" => if(key.user_handle, do: WebAuthn.encode(key.user_handle), else: "")
    }

    {params, %{key | count: count}}
  end

  defp auth_data(flags, count, opts) do
    rp_id = Keyword.get(opts, :rp_id, WebAuthn.rp_id())
    :crypto.hash(:sha256, rp_id) <> <<flags, count::32>>
  end

  defp client_data(type, options, opts) do
    Jason.encode!(%{
      type: type,
      challenge: options[:challenge] || options["challenge"],
      origin: Keyword.get(opts, :origin, WebAuthn.origin())
    })
  end

  defp bytes(binary), do: %CBOR.Tag{tag: :bytes, value: binary}
end
