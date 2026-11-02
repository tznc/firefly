defmodule FirestormWeb.WebAuthn do
  @moduledoc """
  WebAuthn plumbing (on the `wax_` library) for security keys: making the
  options the browser's `navigator.credentials.create/get` take, and
  checking what the authenticator answers.

  The relying party is the site itself: its origin and host come from the
  endpoint's URL (`FIREFLY_DOMAIN`). Challenges are single-use and expire
  after 5 minutes; whoever issues one keeps it until the answer comes back
  (a LiveView in its state, a controller in the session via
  `to_session/1`). Attestation isn't asked for: any authenticator will do.
  Binary fields travel base64url-encoded.

  A credential's signature counter must go up with every use (when the
  authenticator keeps one): a counter that doesn't means the key was
  cloned, and the login is refused.
  """

  alias FirestormWeb.Forums.User
  alias FirestormWeb.Repo
  alias FirestormWeb.TwoFactor.Credential

  @timeout 300

  @doc "The site's origin, e.g. `https://firefly.tznc.dev`."
  def origin, do: FirestormWeb.Web.Endpoint.url()

  @doc "The relying party id: the site's host."
  def rp_id, do: URI.parse(origin()).host

  defp base_opts(user_verification),
    do: [
      origin: origin(),
      rp_id: rp_id(),
      timeout: @timeout,
      user_verification: user_verification
    ]

  @doc """
  A registration challenge, and the options for
  `navigator.credentials.create` (as JSON-ready maps) to register a new
  credential for `user` (`existing` credentials are excluded).
  """
  def registration(%User{} = user, existing, user_verification \\ "discouraged") do
    challenge =
      Wax.new_registration_challenge([attestation: "none"] ++ base_opts(user_verification))

    options = %{
      challenge: encode(challenge.bytes),
      rp: %{id: rp_id(), name: FirestormWeb.SiteSettings.get("title")},
      user: %{id: encode(user_handle(user)), name: user.username, displayName: user.name},
      pubKeyCredParams: Enum.map([-7, -8, -257], &%{type: "public-key", alg: &1}),
      timeout: @timeout * 1000,
      attestation: "none",
      excludeCredentials:
        Enum.map(existing, &%{type: "public-key", id: encode(&1.credential_id)}),
      authenticatorSelection: %{userVerification: user_verification}
    }

    {challenge, options}
  end

  @doc "The user handle credentials are registered with: the user's id."
  def user_handle(%User{id: id}), do: Integer.to_string(id)

  @doc """
  Checks a registration answer (`attestation_object` and
  `client_data_json`, base64url): `{:ok, attrs}` with the credential's
  `credential_id`, `public_key` and `sign_count` to save, or
  `{:error, reason}`.
  """
  def register(challenge, %{"attestation_object" => object, "client_data_json" => client_data}) do
    with {:ok, object} <- decode(object),
         {:ok, client_data} <- decode(client_data),
         {:ok, {auth_data, _attestation}} <- Wax.register(object, client_data, challenge) do
      credential = auth_data.attested_credential_data

      {:ok,
       %{
         credential_id: credential.credential_id,
         public_key: :erlang.term_to_binary(credential.credential_public_key),
         sign_count: auth_data.sign_count
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def register(_challenge, _params), do: {:error, :invalid}

  @doc """
  An authentication challenge for `credentials` (all of a user's, or none
  for a discoverable credential: the authenticator picks the account), and
  the options for `navigator.credentials.get`.
  """
  def authentication(credentials, user_verification \\ "discouraged") do
    allowed = Enum.map(credentials, &{&1.credential_id, Credential.cose_key(&1)})

    challenge =
      Wax.new_authentication_challenge(
        [allow_credentials: allowed] ++ base_opts(user_verification)
      )

    {challenge, request_options(challenge, credentials)}
  end

  @doc "The options for `navigator.credentials.get` for `challenge` and `credentials`."
  def request_options(challenge, credentials) do
    %{
      challenge: encode(challenge.bytes),
      rpId: rp_id(),
      timeout: @timeout * 1000,
      userVerification: challenge.user_verification,
      allowCredentials:
        Enum.map(credentials, &%{type: "public-key", id: encode(&1.credential_id)})
    }
  end

  @doc """
  Checks an authentication answer (`id`, `authenticator_data`,
  `signature`, `client_data_json`, base64url) against `credentials`, the
  ones it may come from. On success, records the use and returns
  `{:ok, credential}`.
  """
  def authenticate(challenge, credentials, %{
        "id" => id,
        "authenticator_data" => auth_data,
        "signature" => signature,
        "client_data_json" => client_data
      }) do
    with {:ok, id} <- decode(id),
         %Credential{} = credential <- Enum.find(credentials, &(&1.credential_id == id)),
         {:ok, auth_data} <- decode(auth_data),
         {:ok, signature} <- decode(signature),
         {:ok, client_data} <- decode(client_data),
         {:ok, %{sign_count: count}} <-
           Wax.authenticate(id, auth_data, signature, client_data, challenge, [
             {id, Credential.cose_key(credential)}
           ]),
         :ok <- check_counter(credential, count) do
      {:ok, used(credential, count)}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def authenticate(_challenge, _credentials, _params), do: {:error, :invalid}

  # Authenticators without a counter always say 0.
  defp check_counter(%Credential{sign_count: stored}, count)
       when count > stored or (count == 0 and stored == 0),
       do: :ok

  defp check_counter(_credential, _count), do: {:error, :cloned}

  defp used(credential, count) do
    credential
    |> Ecto.Changeset.change(sign_count: count, last_used_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  @doc "A challenge to keep in the session until the answer comes back."
  def to_session(%Wax.Challenge{bytes: bytes, issued_at: issued_at}),
    do: %{"bytes" => encode(bytes), "issued_at" => issued_at}

  @doc """
  The authentication challenge kept with `to_session/1`, for `credentials`
  (or nil when there's none).
  """
  def from_session(stored, credentials, user_verification \\ "discouraged")

  def from_session(%{"bytes" => bytes, "issued_at" => issued_at}, credentials, user_verification) do
    {challenge, _options} = authentication(credentials, user_verification)
    %{challenge | bytes: Base.url_decode64!(bytes, padding: false), issued_at: issued_at}
  end

  def from_session(_stored, _credentials, _user_verification), do: nil

  @doc "Encodes binary as unpadded base64url, as WebAuthn's JSON uses."
  def encode(binary), do: Base.url_encode64(binary, padding: false)

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_value), do: :error
end
