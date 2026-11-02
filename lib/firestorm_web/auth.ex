defmodule FirestormWeb.Auth do
  @moduledoc """
  Logging in with other sites ("social logins"): GitHub, Google, Discord,
  Apple, X, Facebook and Slack, through Ueberauth strategies (the
  `ueberauth_*` packages; X and Slack are small in-house strategies under
  `FirestormWeb.Auth.Strategies`).

  A provider is enabled only when its client id and secret are configured
  (`FIREFLY_<PROVIDER>_CLIENT_ID` / `_CLIENT_SECRET`, see
  `config/runtime.exs`): only enabled providers get a login button or
  accept a login (see `FirestormWeb.Web.Plugs.LoginProviders`).

  Accounts are linked to users by the provider's immutable account id
  (`user_identities`; one account per provider per user), never by
  username or email. A login with an unknown account creates a new user,
  if registrations are open (the `allow_registrations` setting), named
  after the account (made unique). The new account's email address counts
  as confirmed only when the provider says it verified it; otherwise the
  user confirms it as anyone else would (`require_email_confirmation`).
  New members' posts still wait for approval when the site asks for that
  (see `FirestormWeb.Forums.approval_required?/1`).

  Logged-in users connect more providers, and disconnect them, from their
  settings; the last way to log in (with no password) can't be removed.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.{User, UserIdentity}
  alias FirestormWeb.Plugins.Events

  @providers [
    github: {"GitHub", Ueberauth.Strategy.Github.OAuth},
    google: {"Google", Ueberauth.Strategy.Google.OAuth},
    discord: {"Discord", Ueberauth.Strategy.Discord.OAuth},
    apple: {"Apple", Ueberauth.Strategy.Apple.OAuth},
    x: {"X", FirestormWeb.Auth.Strategies.X},
    facebook: {"Facebook", Ueberauth.Strategy.Facebook.OAuth},
    slack: {"Slack", FirestormWeb.Auth.Strategies.Slack}
  ]

  @names Enum.map(@providers, fn {provider, _} -> to_string(provider) end)

  @doc "Every provider, in display order."
  def providers, do: Keyword.keys(@providers)

  @doc "The providers with credentials configured, in display order."
  def enabled_providers, do: Enum.filter(providers(), &enabled?/1)

  @doc "Whether `provider` (an atom or its name) has credentials configured."
  def enabled?(provider) when is_binary(provider) and provider in @names,
    do: enabled?(String.to_existing_atom(provider))

  def enabled?(provider) when is_atom(provider) do
    case @providers[provider] do
      nil ->
        false

      {_label, config_key} ->
        config = Application.get_env(:ueberauth, config_key, [])
        present?(config[:client_id]) and present?(config[:client_secret])
    end
  end

  def enabled?(_provider), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  @doc "The provider's name for people, e.g. `\"GitHub\"`."
  def label(provider) when is_binary(provider), do: label(String.to_existing_atom(provider))
  def label(provider), do: @providers |> Keyword.fetch!(provider) |> elem(0)

  @doc """
  What we use from a successful Ueberauth login: `%{provider, uid,
  nickname, name, email, email_verified}`.
  """
  def from_ueberauth(%Ueberauth.Auth{provider: provider, uid: uid, info: info} = auth) do
    raw = raw_user(auth)

    name =
      info.name ||
        [info.first_name, info.last_name] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> blank()

    %{
      provider: provider,
      uid: uid,
      nickname: info.nickname,
      name: name,
      email: info.email,
      email_verified: email_verified?(provider, raw)
    }
  end

  defp blank(""), do: nil
  defp blank(text), do: text

  defp raw_user(%{extra: %{raw_info: %{user: user}}}) when is_map(user), do: user
  defp raw_user(_auth), do: %{}

  # Whether the provider vouches for the email address: GitHub (its primary
  # address), Apple and Facebook only give verified ones; Google, Discord
  # and Slack say; X gives none.
  defp email_verified?(provider, _raw) when provider in [:github, :apple, :facebook], do: true
  defp email_verified?(:discord, raw), do: raw["verified"] == true

  defp email_verified?(provider, raw) when provider in [:google, :slack],
    do: raw["email_verified"] in [true, "true"]

  defp email_verified?(_provider, _raw), do: false

  @doc """
  Logs in (or registers) the user with the provider account in `info` (see
  `from_ueberauth/1`; `provider` and `uid` are required).

  For accounts GitHub logins created before account ids were stored, the
  GitHub account is linked to a user of the same username only if that
  user has no password and no linked account, and the emails match.
  """
  def login(%{provider: provider, uid: uid} = info) when not is_nil(uid) do
    provider = to_string(provider)
    uid = to_string(uid)

    case identity_user(provider, uid) do
      %User{} = user -> {:ok, user}
      nil -> link_legacy_or_register(provider, uid, info)
    end
  end

  def login(%{provider: provider}),
    do: {:error, "#{label(to_string(provider))} did not return an account id."}

  defp identity_user(provider, uid) do
    User
    |> join(:inner, [u], i in UserIdentity,
      on: i.user_id == u.id and i.provider == ^provider and i.uid == ^uid
    )
    |> Repo.one()
  end

  defp link_legacy_or_register("github", uid, info) do
    email = info[:email] || "#{info[:nickname]}@users.noreply.github.com"

    case legacy_github_user(info[:nickname], email) do
      %User{} = user -> with {:ok, _} <- link(user, "github", uid, info), do: {:ok, user}
      nil -> register("github", uid, Map.put(info, :email, email))
    end
  end

  defp link_legacy_or_register(provider, uid, info), do: register(provider, uid, info)

  defp legacy_github_user(nil, _email), do: nil

  defp legacy_github_user(nickname, email) do
    Repo.one(
      from(u in User,
        as: :user,
        where: u.username == ^nickname and is_nil(u.password_hash) and is_nil(u.deleted_at),
        where: fragment("lower(?)", u.email) == ^String.downcase(email),
        where: not exists(from(i in UserIdentity, where: i.user_id == parent_as(:user).id))
      )
    )
  end

  defp register(provider, uid, info) do
    if Forums.registration_open?(),
      do: insert_user(provider, uid, info),
      else: {:error, "New registrations are closed."}
  end

  defp insert_user(provider, uid, info) do
    username = available_username(provider, base_username(info))

    result =
      Repo.transact(fn ->
        with {:ok, user} <-
               %User{confirmed_at: if(info[:email_verified], do: DateTime.utc_now(:second))}
               |> User.changeset(%{
                 username: username,
                 name: info[:name] || username,
                 email: info[:email],
                 api_token: Ecto.UUID.generate()
               })
               |> Repo.insert(),
             {:ok, _identity} <- link(user, provider, uid, info) do
          {:ok, user}
        end
      end)

    with {:ok, user} <- result do
      Events.emit("user_registered", %{user: %{id: user.id, username: user.username}})
      {:ok, user}
    end
  end

  # A username from the account's nickname, else its email or name, made
  # of the characters usernames allow.
  defp base_username(info) do
    email_name = info[:email] && hd(String.split(info[:email], "@"))

    [info[:nickname], email_name, info[:name]]
    |> Enum.map(&(&1 && &1 |> String.replace(~r/[^A-Za-z0-9_-]/, "") |> String.slice(0, 24)))
    |> Enum.find("user", &(is_binary(&1) and String.length(&1) >= 2))
  end

  # Taken names get a number; one named like a deleted account's
  # placeholder gets the provider as a prefix (see `User.reserved_username?/1`).
  defp available_username(provider, name, attempt \\ 0) do
    candidate = if attempt == 0, do: name, else: "#{name}-#{attempt}"

    cond do
      User.reserved_username?(name) -> available_username(provider, "#{prefix(provider)}-#{name}")
      Forums.get_user_by_username(candidate) -> available_username(provider, name, attempt + 1)
      true -> candidate
    end
  end

  defp prefix("github"), do: "gh"
  defp prefix(provider), do: provider

  @doc """
  Connects the provider account in `info` to `user`. Fails if it's linked
  to someone else, or `user` already has an account there.
  """
  def connect(%User{} = user, %{provider: provider, uid: uid} = info) when not is_nil(uid) do
    case link(user, to_string(provider), to_string(uid), info) do
      {:ok, identity} -> {:ok, identity}
      {:error, %Ecto.Changeset{errors: [{_field, {message, _}} | _]}} -> {:error, message}
    end
  end

  def connect(_user, _info), do: {:error, "The provider did not return an account id."}

  defp link(user, provider, uid, info) do
    stored =
      info |> Map.take([:nickname, :name, :email]) |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %UserIdentity{}
    |> UserIdentity.changeset(%{user_id: user.id, provider: provider, uid: uid, info: stored})
    |> Repo.insert()
  end

  @doc "`user`'s connected accounts, by provider name."
  def identities(%User{id: user_id}) do
    UserIdentity
    |> where([i], i.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(&{&1.provider, &1})
  end

  @doc """
  Disconnects `user`'s account at `provider`, unless it's their only way
  to log in (no password, no other account).
  """
  def disconnect(%User{} = user, provider) when is_binary(provider) do
    identities = identities(user)

    cond do
      not Map.has_key?(identities, provider) ->
        {:error, "That account isn't connected."}

      is_nil(user.password_hash) and map_size(identities) == 1 ->
        {:error, "Connect another account first: this is your only way to log in."}

      true ->
        Repo.delete!(identities[provider])
        :ok
    end
  end

  @doc "The export of `user`'s connected accounts (see `FirestormWeb.AccountExport`)."
  def export(%User{} = user) do
    for {_provider, identity} <- identities(user) do
      Map.take(identity, [:provider, :uid, :info, :inserted_at])
    end
  end
end
