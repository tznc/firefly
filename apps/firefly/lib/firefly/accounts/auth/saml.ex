defmodule Firefly.Accounts.Auth.SAML do
  @moduledoc """
  Logging in with a SAML 2.0 identity provider (Okta, Azure AD / Entra ID,
  ADFS, Keycloak, Google Workspace...): Firefly is the service provider.

  Admins configure it in the site settings (section "SAML"): the identity
  provider's metadata (a URL, fetched and cached for an hour, or pasted
  XML) and/or its entity id, login URL and signing certificate, which
  override the metadata's; this site's entity id (by default its metadata
  URL, `/saml/metadata`); which attributes carry the account id (by
  default the `NameID`), email, username, name and groups. Signing our
  requests takes a key and certificate from the deployment
  (`FIREFLY_SAML_SP_KEY`, `FIREFLY_SAML_SP_CERT`, PEM; see
  `config/runtime.exs`).

  A login: `request/1` records a request (its id, valid 10 minutes, kept
  in the browser's session too) and gives the identity provider's URL
  with an `AuthnRequest` (HTTP-Redirect binding, signed when set up) and
  the page to come back to as `RelayState`. The identity provider posts
  its response to our assertion consumer service, which `consume/2`
  verifies (see `Firefly.Accounts.Auth.SAML.Response`: signatures against
  the configured certificates only, shape checks against signature
  wrapping, issuer, audience, recipient, time and request) and stores
  with its request; each assertion is accepted once. That post comes from
  the identity provider's page, so the browser doesn't send our
  (SameSite=Lax) session cookie with it: the browser is sent on to a page
  that does get it, where `take/1` hands over the answer to the request
  that session started. Responses answering no request (logins started
  at the identity provider) are refused unless the `saml_idp_initiated`
  setting allows them: they can't be tied to a browser, so a site could
  log its visitors into an account of its choosing.

  Accounts link by the account id (provider `"saml"` in `user_identities`,
  see `Firefly.Accounts.Auth`), which also covers invites, closed
  registrations, single sign-on only mode and two-factor after SSO.
  """

  import Ecto.Query, only: [from: 2]

  alias Firefly.{Repo, SiteSettings, URLs}
  alias Firefly.Accounts.Auth
  alias Firefly.Accounts.Auth.{GroupSync, HTTP}
  alias Firefly.Accounts.Auth.SAML.{Metadata, Response}

  @request_seconds 600
  @ticket_seconds 120
  @metadata_ttl 3600
  @protocol "urn:oasis:names:tc:SAML:2.0:protocol"
  @assertion "urn:oasis:names:tc:SAML:2.0:assertion"
  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  defp setting(key), do: SiteSettings.get("saml_" <> key)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  Whether SAML logins are on and an identity provider is configured
  (metadata, or a login URL and certificate).
  """
  def enabled? do
    setting("enabled") and
      (present?(setting("idp_metadata_url")) or present?(setting("idp_metadata_xml")) or
         (present?(setting("idp_sso_url")) and present?(setting("idp_certificate"))))
  end

  @doc "The identity provider's name for people (the `saml_name` setting)."
  def label, do: setting("name")

  @doc "This site as a service provider: `entity_id` and `acs_url`."
  def service_provider do
    entity_id = setting("sp_entity_id")

    %{
      entity_id: if(present?(entity_id), do: entity_id, else: URLs.saml_metadata_url()),
      acs_url: URLs.saml_acs_url()
    }
  end

  @doc "Our metadata, for the identity provider."
  def metadata do
    sp = service_provider()
    Metadata.service_provider(sp.entity_id, sp.acs_url, signing_certificate())
  end

  # The key and certificate requests are signed with, when signing is on
  # and both are configured.
  defp signing_key do
    with true <- setting("sign_requests"),
         [entry | _] <- :public_key.pem_decode(config()[:sp_key] || ""),
         [_cert | _] <- Metadata.certificates_from_pem(config()[:sp_cert] || "") do
      :public_key.pem_entry_decode(entry)
    else
      _off -> nil
    end
  end

  defp signing_certificate do
    if signing_key(), do: hd(Metadata.certificates_from_pem(config()[:sp_cert]))
  end

  @doc """
  The identity provider: `{:ok, %{entity_id, sso_url, keys}}` from its
  metadata and the settings, or `{:error, :not_configured}` (or the
  metadata's error).
  """
  def identity_provider do
    with {:ok, metadata} <- idp_metadata() do
      certificates =
        metadata.certificates ++ Metadata.certificates_from_pem(setting("idp_certificate"))

      idp = %{
        entity_id: override(setting("idp_entity_id"), metadata.entity_id),
        sso_url: override(setting("idp_sso_url"), metadata.sso_url),
        keys: certificates |> Enum.map(&Metadata.public_key/1) |> Enum.reject(&is_nil/1)
      }

      if present?(idp.entity_id) and present?(idp.sso_url) and idp.keys != [],
        do: {:ok, idp},
        else: {:error, :not_configured}
    end
  end

  defp override(value, default), do: if(present?(value), do: String.trim(value), else: default)

  defp idp_metadata do
    cond do
      present?(setting("idp_metadata_xml")) -> Metadata.parse_idp(setting("idp_metadata_xml"))
      present?(setting("idp_metadata_url")) -> fetch_metadata(setting("idp_metadata_url"))
      true -> {:ok, %{entity_id: nil, sso_url: nil, certificates: []}}
    end
  end

  defp fetch_metadata(url) do
    key = {__MODULE__, :metadata, url}
    now = System.monotonic_time(:second)

    case :persistent_term.get(key, nil) do
      {fetched_at, metadata} when now - fetched_at < @metadata_ttl ->
        {:ok, metadata}

      _stale ->
        with {:ok, xml} <- HTTP.get(url),
             {:ok, metadata} <- Metadata.parse_idp(xml) do
          :persistent_term.put(key, {now, metadata})
          {:ok, metadata}
        else
          _failed -> {:error, :metadata_unavailable}
        end
    end
  end

  @doc """
  Starts a login that returns to `return_to` (a path here): records the
  request and returns `{:ok, request_id, url}` (the identity provider's
  login URL) or `{:error, reason}`.
  """
  def request(return_to) do
    with {:ok, idp} <- identity_provider() do
      id = new_id()
      now = DateTime.utc_now(:second)
      Repo.delete_all(from(r in "saml_requests", where: r.expires_at < ^now))

      Repo.insert_all("saml_requests", [
        %{id: id, return_to: return_to, expires_at: DateTime.add(now, @request_seconds)}
      ])

      {:ok, id, redirect_url(idp.sso_url, authn_request(id, idp.sso_url, now), return_to)}
    end
  end

  # NCNames: they can't start with a digit.
  defp new_id, do: "_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  defp authn_request(id, destination, now) do
    sp = service_provider()

    ~s{<samlp:AuthnRequest xmlns:samlp="#{@protocol}" xmlns:saml="#{@assertion}" ID="#{id}" } <>
      ~s{Version="2.0" IssueInstant="#{DateTime.to_iso8601(now)}" Destination="#{Metadata.escape(destination)}" } <>
      ~s{AssertionConsumerServiceURL="#{Metadata.escape(sp.acs_url)}" } <>
      ~s{ProtocolBinding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST">} <>
      ~s{<saml:Issuer>#{Metadata.escape(sp.entity_id)}</saml:Issuer>} <>
      ~s{<samlp:NameIDPolicy AllowCreate="true"/></samlp:AuthnRequest>}
  end

  # The HTTP-Redirect binding: the request deflated, Base64-encoded and
  # URL-encoded, signed over the exact query string when signing is on.
  defp redirect_url(sso_url, request, relay_state) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    deflated = IO.iodata_to_binary(:zlib.deflate(z, request, :finish))
    :zlib.close(z)

    query =
      URI.encode_query([{"SAMLRequest", Base.encode64(deflated)}, {"RelayState", relay_state}])

    query =
      case signing_key() do
        nil ->
          query

        key ->
          signed = query <> "&" <> URI.encode_query([{"SigAlg", @rsa_sha256}])
          signature = Base.encode64(:public_key.sign(signed, :sha256, key))
          signed <> "&" <> URI.encode_query([{"Signature", signature}])
      end

    sso_url <> if(String.contains?(sso_url, "?"), do: "&", else: "?") <> query
  end

  @doc """
  Verifies the identity provider's `saml_response` and keeps its answer
  for the browser to pick up (see `take/1`): `{:ok, :solicited}` (it
  answers a request of ours), `{:ok, {:unsolicited, ticket}}` (when those
  are allowed; `relay_state` is where to go next) or `{:error, reason}`.
  """
  def consume(saml_response, relay_state, opts \\ []) do
    with :ok <- if(enabled?(), do: :ok, else: {:error, :not_configured}),
         {:ok, idp} <- identity_provider(),
         {:ok, assertion} <-
           Response.verify(
             saml_response,
             idp,
             service_provider(),
             Keyword.put(opts, :unsolicited, setting("idp_initiated"))
           ),
         :ok <- use_assertion(assertion) do
      result = %{"name_id" => assertion.name_id, "attributes" => assertion.attributes}
      answer(assertion.in_response_to, result, relay_state)
    end
  end

  defp use_assertion(%{id: id, expires_at: expires_at}) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(a in "saml_assertions", where: a.expires_at < ^now))

    case Repo.insert_all(
           "saml_assertions",
           [%{id: id, expires_at: DateTime.truncate(expires_at, :second)}],
           on_conflict: :nothing
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :replayed}
    end
  end

  defp answer(nil, result, relay_state) do
    ticket = new_id()
    expires_at = DateTime.add(DateTime.utc_now(:second), @ticket_seconds)
    return_to = if is_binary(relay_state) and byte_size(relay_state) <= 255, do: relay_state

    Repo.insert_all("saml_requests", [
      %{id: ticket, return_to: return_to || "/", result: result, expires_at: expires_at}
    ])

    {:ok, {:unsolicited, ticket}}
  end

  defp answer(request_id, result, _relay_state) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(r in "saml_requests",
             where: r.id == ^request_id and is_nil(r.result) and r.expires_at >= ^now
           ),
           set: [result: result]
         ) do
      {1, _} -> {:ok, :solicited}
      {0, _} -> {:error, :unknown_request}
    end
  end

  @doc """
  Hands over (once) the verified answer to the request (or unsolicited
  ticket) `id`: `{:ok, %{result, return_to}}` or `{:error, :expired}`.
  """
  def take(id) when is_binary(id) do
    now = DateTime.utc_now(:second)

    case Repo.delete_all(
           from(r in "saml_requests",
             where: r.id == ^id and not is_nil(r.result) and r.expires_at >= ^now,
             select: %{result: type(r.result, :map), return_to: r.return_to}
           )
         ) do
      {1, [answer]} -> {:ok, answer}
      _none -> {:error, :expired}
    end
  end

  def take(_id), do: {:error, :expired}

  @doc "A message for a `request/1`, `consume/2` or `take/1` error."
  def message(:expired), do: "That login expired or was used already. Try again."
  def message(:unknown_request), do: "That login expired or was used already. Try again."
  def message(:replayed), do: "That login was used already. Try again."
  def message(:login_failed), do: "#{label()} didn't log you in."
  def message(:unsolicited), do: "Start #{label()} logins here, at the login page."

  def message(reason) when reason in [:not_configured, :metadata_unavailable],
    do: "#{label()} login isn't available right now."

  def message(_reason), do: "#{label()} login failed. Try again."

  @doc "What `Firefly.Accounts.Auth.login/2` and `connect/2` use from a verified answer."
  def info(%{"name_id" => name_id, "attributes" => attributes}) do
    uid_attribute = setting("uid_attribute")

    %{
      provider: :saml,
      uid:
        if(present?(uid_attribute), do: first(attributes, uid_attribute), else: blank(name_id)),
      nickname: first(attributes, setting("username_attributes")),
      name: first(attributes, setting("name_attributes")),
      email: first(attributes, setting("email_attributes")),
      email_verified: setting("trust_email")
    }
  end

  # The first value of the first of `names` (comma-separated) present.
  defp first(attributes, names) do
    names
    |> attribute_names()
    |> Enum.find_value(&(attributes[&1] |> List.wrap() |> Enum.find(fn v -> present?(v) end)))
  end

  defp attribute_names(names), do: names |> String.split(",") |> Enum.map(&String.trim/1)

  defp blank(value), do: if(present?(value), do: value)

  @doc "Logs in (or registers) the account in the verified answer `result`, then syncs it."
  def login(result, invite \\ nil) do
    with {:ok, user} <- Auth.login(info(result), invite), do: {:ok, sync(user, result)}
  end

  @doc """
  Brings `user`'s groups in line with the answer's, when a groups
  attribute is set (an answer without it means no groups).
  """
  def sync(user, %{"attributes" => attributes}) do
    names = setting("groups_attributes")

    if present?(names) do
      groups =
        names
        |> attribute_names()
        |> Enum.flat_map(&List.wrap(attributes[&1]))
        |> Enum.uniq()

      GroupSync.mirror(user, groups)
    end

    user
  end
end
