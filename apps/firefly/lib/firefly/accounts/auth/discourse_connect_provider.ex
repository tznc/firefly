defmodule Firefly.Accounts.Auth.DiscourseConnectProvider do
  @moduledoc """
  Firefly as a DiscourseConnect provider: other sites (a Discourse forum, a
  wiki, anything speaking the protocol) log their visitors in with their
  Firefly accounts. The reverse of `Firefly.Accounts.Auth.DiscourseConnect`.

  It's on with the `discourse_connect_provider_enabled` setting, for the
  clients admins add at `/staff/discourse-connect` (each change goes to
  the staff log): each has its own secret and the hosts it may send people
  back to.

  A client sends the browser to `/session/sso_provider` with `sso` (Base64
  of `nonce`, `return_sso_url` and optionally `prompt=none` or
  `logout=true`) and `sig`, its HMAC-SHA256 under the client's secret. We
  pick the clients allowed to return to that URL's host and accept the
  request only if one's secret signs it. The browser must be logged in
  here (and, with `discourse_connect_provider_require_two_factor`, have
  two-factor authentication on) before we answer: back at `return_sso_url`
  with the user's `external_id` (their id here), `email`, `username`,
  `name`, `avatar_url`, `groups`, `admin` and `moderator`, signed the same
  way. Each nonce is answered once.
  """

  import Ecto.Query

  alias Firefly.{Accounts, Endpoint, Repo, SiteSettings}
  alias Firefly.Accounts.{TwoFactor, User}
  alias Firefly.Accounts.Auth.DiscourseConnectClient, as: Client
  alias Firefly.Groups.Role
  alias Firefly.Moderation.StaffLog

  @nonce_seconds 3600

  @doc "Whether other sites may log people in through Firefly (the setting)."
  def enabled?, do: SiteSettings.get("discourse_connect_provider_enabled")

  ## Clients

  @doc "The clients, by name."
  def list_clients, do: Repo.all(from(c in Client, order_by: [asc: c.name, asc: c.id]))

  def get_client!(id), do: Repo.get!(Client, id)

  @doc "A form changeset for `client` (a new one, with a fresh secret, by default)."
  def change_client(client \\ %Client{secret: new_secret()}, attrs \\ %{}) do
    client = %{client | hosts: Enum.join(client.allowed_hosts, "\n")}
    Client.changeset(client, attrs)
  end

  @doc "A random secret for a client."
  def new_secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "Adds a client, logged as `admin`'s."
  def create_client(attrs, admin) do
    Repo.transact(fn ->
      with {:ok, client} <- %Client{} |> Client.changeset(attrs) |> Repo.insert() do
        log(admin, "discourse_connect_client.create", client)
        {:ok, client}
      end
    end)
  end

  @doc "Changes a client's name, hosts or secret, logged as `admin`'s."
  def update_client(%Client{} = client, attrs, admin) do
    Repo.transact(fn ->
      with {:ok, updated} <- client |> Client.changeset(attrs) |> Repo.update() do
        log(admin, "discourse_connect_client.update", updated, %{
          secret_changed: updated.secret != client.secret
        })

        {:ok, updated}
      end
    end)
  end

  @doc "Removes a client, logged as `admin`'s."
  def delete_client(%Client{} = client, admin) do
    Repo.transact(fn ->
      log(admin, "discourse_connect_client.delete", client)
      Repo.delete(client)
    end)
  end

  defp log(admin, action, client, details \\ %{}) do
    StaffLog.record(
      admin,
      action,
      {"discourse_connect_client", client.id},
      Map.merge(%{name: client.name, hosts: client.allowed_hosts}, details)
    )
  end

  ## Requests

  @doc """
  Checks a client's request: `{:ok, request}` (`client`, `nonce`,
  `return_url`, `prompt_none?`, `logout?`) or `{:error, reason}`
  (`:bad_payload`, `:unknown_return_url`, `:bad_signature`).
  """
  def verify(sso, sig) when is_binary(sso) and is_binary(sig) do
    with {:ok, params} <- decode(sso),
         {:ok, return_url, host} <- return_url(params["return_sso_url"]),
         {:ok, client} <- signing_client(host, sso, sig),
         {:ok, nonce} <- nonce(params["nonce"]) do
      {:ok,
       %{
         client: client,
         nonce: nonce,
         return_url: return_url,
         prompt_none?: params["prompt"] == "none",
         logout?: params["logout"] == "true"
       }}
    end
  end

  def verify(_sso, _sig), do: {:error, :bad_payload}

  defp decode(sso) do
    case Base.decode64(sso, ignore: :whitespace) do
      {:ok, query} -> {:ok, URI.decode_query(query)}
      :error -> {:error, :bad_payload}
    end
  rescue
    _invalid_query -> {:error, :bad_payload}
  end

  defp return_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, url, String.downcase(host)}

      _other ->
        {:error, :unknown_return_url}
    end
  end

  defp return_url(_url), do: {:error, :bad_payload}

  # The clients allowed to return to `host`, whichever one's secret signs.
  defp signing_client(host, sso, sig) do
    clients = Repo.all(from(c in Client, where: ^host in c.allowed_hosts))

    cond do
      clients == [] -> {:error, :unknown_return_url}
      client = Enum.find(clients, &signed?(&1, sso, sig)) -> {:ok, client}
      true -> {:error, :bad_signature}
    end
  end

  defp signed?(client, sso, sig),
    do: Plug.Crypto.secure_compare(sign(client, sso), String.downcase(sig))

  defp nonce(nonce) when is_binary(nonce) and byte_size(nonce) in 1..255, do: {:ok, nonce}
  defp nonce(_nonce), do: {:error, :bad_payload}

  @doc "`payload`'s signature under `client`'s secret, in lowercase hex."
  def sign(%Client{secret: secret}, payload),
    do: :hmac |> :crypto.mac(:sha256, secret, payload) |> Base.encode16(case: :lower)

  @doc """
  Whether `user` must turn on two-factor authentication before being
  logged in elsewhere (the `discourse_connect_provider_require_two_factor`
  setting).
  """
  def two_factor_required?(%User{} = user) do
    SiteSettings.get("discourse_connect_provider_require_two_factor") and
      not TwoFactor.enabled?(user)
  end

  @doc """
  The answer to `request` for `user`: `{:ok, url}` (the client's return URL
  with the signed payload) or `{:error, :replayed}` when the nonce was
  answered already.
  """
  def answer(request, %User{} = user) do
    with :ok <- use_nonce(request) do
      {:ok, reply(request, user_fields(user))}
    end
  end

  @doc "The answer to a `prompt=none` request when nobody's logged in: `failed=true`."
  def answer_failed(request) do
    with :ok <- use_nonce(request), do: {:ok, reply(request, %{"failed" => "true"})}
  end

  @doc "Uses up a logout request's nonce: `:ok` or `{:error, :replayed}`."
  def logout(request), do: use_nonce(request)

  defp use_nonce(%{client: client, nonce: nonce}) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from(n in "discourse_connect_provider_nonces", where: n.expires_at < ^now))

    case Repo.insert_all(
           "discourse_connect_provider_nonces",
           [%{client_id: client.id, nonce: nonce, expires_at: DateTime.add(now, @nonce_seconds)}],
           on_conflict: :nothing
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :replayed}
    end
  end

  defp user_fields(user) do
    user = Repo.preload(user, :roles, force: true)
    roles = Enum.map(user.roles, & &1.name)
    # Groups people chose: not the staff flags or the trust levels' own.
    groups =
      for role <- user.roles,
          role.name not in ~w(admin moderator) and not Role.automatic?(role),
          do: role.name

    %{
      "external_id" => to_string(user.id),
      "email" => user.email || "",
      "username" => user.username,
      "name" => user.name || "",
      "avatar_url" => absolute(User.avatar_url(user)),
      "groups" => Enum.join(groups, ","),
      "admin" => to_string(Accounts.admin?(user)),
      "moderator" => to_string("moderator" in roles),
      "require_activation" => to_string(not User.confirmed?(user))
    }
  end

  defp absolute("/" <> _ = path), do: Endpoint.url() <> path
  defp absolute(url), do: url

  defp reply(request, fields) do
    payload =
      fields
      |> Map.merge(%{"nonce" => request.nonce, "return_sso_url" => request.return_url})
      |> URI.encode_query()
      |> Base.encode64()

    query = URI.encode_query(%{"sso" => payload, "sig" => sign(request.client, payload)})
    url = request.return_url
    url <> if(String.contains?(url, "?"), do: "&", else: "?") <> query
  end

  @doc "A message for a `verify/2` or `answer/2` error."
  def message(:unknown_return_url), do: "That site isn't allowed to log in with this one."
  def message(:replayed), do: "That login link was used already. Start again from the other site."
  def message(_reason), do: "That login link is invalid. Start again from the other site."
end
