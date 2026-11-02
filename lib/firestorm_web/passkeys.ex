defmodule FirestormWeb.Passkeys do
  @moduledoc """
  Passkeys: discoverable WebAuthn credentials (see `FirestormWeb.WebAuthn`)
  that log in on their own, no username or password. The authenticator
  verifies the user (PIN, biometrics) every time, so a passkey login counts
  as two factors: it skips the second-factor step (see
  `FirestormWeb.TwoFactor.required?/2`).

  Members add, rename and remove them in Settings > Security. The login
  pages offer them (`PasskeyLogin` hook): a button, and the browser's
  autofill on the username field where it supports that (conditional UI);
  `FirestormWeb.Web.PasskeyController` issues the challenge (kept in the
  session) and checks the answer. Passkeys work while the `passkeys` site
  setting is on and passwords are (they're off when single sign-on is the
  only way in).
  """

  import Ecto.Query

  alias FirestormWeb.{Auth, Repo, SiteSettings, WebAuthn}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.TwoFactor.Credential

  @doc "Whether passkeys can be added and used to log in."
  def enabled?, do: SiteSettings.get("passkeys") and Auth.password_login?()

  @doc "`user`'s passkeys, oldest first."
  def list(%User{id: id}),
    do: Repo.all(from(c in Credential, where: c.user_id == ^id and c.passkey, order_by: c.id))

  @doc "Whether `user` has a passkey other than the one with id `except` (while they work)."
  def other?(%User{id: id}, except) do
    enabled?() and
      Repo.exists?(
        from(c in Credential,
          where: c.user_id == ^id and c.passkey and c.id != ^(except || 0)
        )
      )
  end

  @doc """
  A registration challenge and options for a new passkey for `user`,
  excluding the credentials they already have on the same authenticator.
  """
  def registration(%User{} = user) do
    existing = Repo.all(from(c in Credential, where: c.user_id == ^user.id))
    WebAuthn.registration(user, existing, passkey: true)
  end

  @doc "Saves a registered passkey (attrs from `FirestormWeb.WebAuthn.register/2`) as `name`."
  def add(%User{} = user, attrs, name) do
    %Credential{user_id: user.id, passkey: true}
    |> Ecto.Changeset.change(attrs)
    |> Credential.name_changeset(%{name: name})
    |> Ecto.Changeset.unique_constraint(:credential_id, message: "is registered already")
    |> Repo.insert()
  end

  @doc "Renames one of `user`'s passkeys."
  def rename(%User{} = user, id, name) do
    case Repo.get_by(Credential, id: id, user_id: user.id, passkey: true) do
      nil -> {:error, :not_found}
      passkey -> passkey |> Credential.name_changeset(%{name: name}) |> Repo.update()
    end
  end

  @doc "Removes one of `user`'s passkeys, unless it's their only way to log in."
  def delete(%User{} = user, id) do
    with %Credential{} = passkey <-
           Repo.get_by(Credential, id: id, user_id: user.id, passkey: true) ||
             {:error, :not_found},
         true <- Auth.other_way_in?(user, {:passkey, passkey.id}) || {:error, :last_way_in},
         {:ok, _} <- Repo.delete(passkey) do
      :ok
    end
  end

  @doc "A challenge for a passkey login and the options for `navigator.credentials.get`."
  def login_challenge, do: WebAuthn.authentication([], "required")

  @doc """
  Checks a passkey login (`params` from the browser: `id`,
  `authenticator_data`, `signature`, `client_data_json`, `user_handle`)
  against the challenge kept with `FirestormWeb.WebAuthn.to_session/1`.
  Returns `{:ok, user}` or `{:error, :invalid}`.
  """
  def authenticate(stored_challenge, %{"id" => id} = params) when is_binary(id) do
    with true <- enabled?(),
         {:ok, credential_id} <- Base.url_decode64(id, padding: false),
         %Credential{} = passkey <-
           Repo.get_by(Credential, credential_id: credential_id, passkey: true),
         true <- handle_matches?(params["user_handle"], passkey.user_id),
         %Wax.Challenge{} = challenge <-
           WebAuthn.from_session(stored_challenge, [passkey], "required"),
         {:ok, _passkey} <- WebAuthn.authenticate(challenge, [passkey], params),
         %User{deleted_at: nil} = user <- Repo.get(User, passkey.user_id) do
      {:ok, user}
    else
      _invalid -> {:error, :invalid}
    end
  end

  def authenticate(_stored_challenge, _params), do: {:error, :invalid}

  # The authenticator says whose credential it is; it must be the owner's.
  defp handle_matches?(handle, user_id) when is_binary(handle) and handle != "" do
    Base.url_decode64(handle, padding: false) == {:ok, Integer.to_string(user_id)}
  end

  defp handle_matches?(_no_handle, _user_id), do: true

  @doc "A message for an error from this module."
  def message(:not_found), do: "That passkey isn't yours."
  def message(:last_way_in), do: "Add another way to log in first: this is your only one."
  def message(:invalid), do: "That passkey wasn't accepted."

  @doc "The export of `user`'s passkeys: their names and dates, not the keys."
  def export(%User{} = user),
    do: for(c <- list(user), do: Map.take(c, [:name, :inserted_at, :last_used_at]))
end
