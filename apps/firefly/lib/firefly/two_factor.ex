defmodule Firefly.TwoFactor do
  @moduledoc """
  Two-factor authentication: a second proof, after the first (a password,
  a social or SSO login, a magic link), before a login completes.

  Second factors, set up in Settings > Security:

    * an authenticator app: TOTP codes (RFC 6238, 6 digits, 30 seconds),
      enrolled by scanning a QR code (or typing the secret) and entering a
      code. A code works once.
    * security keys (WebAuthn, see `Firefly.WebAuthn`).
    * backup codes: ten single-use codes for when the others are lost,
      issued when two-factor is first turned on and regenerated on demand
      (which voids the old ones). Stored hashed.

  Two-factor is on for a user with an authenticator app or a security
  key. Logging in then asks for a code or a key (see
  `FireflyWeb.TwoFactorController`), attempts rate-limited per user;
  after social and SSO logins too unless the `two_factor_sso_logins` site
  setting is off. With `enforce_two_factor_staff` on, admins must set it
  up before using the site. Admins can reset a member's two-factor (it's
  staff-logged), e.g. when they've lost every factor.
  """

  import Ecto.Query

  alias Firefly.{Forums, Repo, SiteSettings, StaffLog}
  alias Firefly.Forums.User
  alias Firefly.TwoFactor.{BackupCode, Credential, Totp}

  @backup_codes 10

  @doc "Whether `user` has two-factor on (an authenticator app or a security key)."
  def enabled?(%User{id: id}) do
    Repo.exists?(from(t in Totp, where: t.user_id == ^id)) or
      Repo.exists?(from(c in Credential, where: c.user_id == ^id and not c.passkey))
  end

  @doc "Whether `user` has an authenticator app set up."
  def totp?(%User{id: id}), do: Repo.exists?(from(t in Totp, where: t.user_id == ^id))

  @doc """
  Whether a login by `method` (`:password`, `:sso` for social and SSO
  logins, `:magic_link`, `:passkey`) must also pass the second factor.
  A passkey already proves possession and the user's verification.
  """
  def required?(%User{} = user, method) do
    case method do
      :passkey -> false
      :sso -> SiteSettings.get("two_factor_sso_logins") and enabled?(user)
      _password_or_link -> enabled?(user)
    end
  end

  @doc "Whether `user` is staff who must set up two-factor before going on."
  def must_enroll?(%User{} = user) do
    SiteSettings.get("enforce_two_factor_staff") and Forums.admin?(user) and not enabled?(user)
  end

  def must_enroll?(_nobody), do: false

  ## Authenticator apps

  @doc "A new random TOTP secret, for `totp_uri/2` and `enable_totp/3`."
  def new_secret, do: NimbleTOTP.secret()

  @doc "The `otpauth://` URI an authenticator app scans."
  def totp_uri(%User{} = user, secret),
    do:
      NimbleTOTP.otpauth_uri("#{SiteSettings.get("title")}:#{user.username}", secret,
        issuer: SiteSettings.get("title")
      )

  @doc "The URI as an SVG QR code."
  def qr_svg(uri), do: uri |> EQRCode.encode() |> EQRCode.svg(width: 200)

  @doc "The secret as people type it: base32, in groups of four."
  def display_secret(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @doc """
  Turns on the authenticator app with `secret` once `code` proves it's set
  up. Returns `{:ok, backup_codes}`, new codes if the user had none (else
  `[]`), or `{:error, :invalid_code}`.
  """
  def enable_totp(%User{} = user, secret, code) do
    if totp_valid?(secret, normalize(code), nil) do
      Repo.transact(fn ->
        Repo.delete_all(from(t in Totp, where: t.user_id == ^user.id))

        Repo.insert!(%Totp{user_id: user.id, secret: secret})

        {:ok, if(backup_codes_left(user) == 0, do: insert_backup_codes(user), else: [])}
      end)
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Turns off the authenticator app, confirmed by `confirmation`: the
  user's password or a current code (see `verify_code/2`).
  """
  def disable_totp(%User{} = user, confirmation) do
    with :ok <- confirm(user, confirmation) do
      Repo.delete_all(from(t in Totp, where: t.user_id == ^user.id))
      unless enabled?(user), do: delete_backup_codes(user)
      :ok
    end
  end

  @doc "Checks `confirmation` against the user's password, else as a second-factor code."
  def confirm(%User{password_hash: hash} = user, confirmation) when is_binary(confirmation) do
    if is_binary(hash) and Bcrypt.verify_pass(confirmation, hash),
      do: :ok,
      else: verify_code(user, confirmation)
  end

  def confirm(_user, _confirmation), do: {:error, :invalid_code}

  @doc """
  Checks a code at login: a current authenticator code (one not used
  before) or an unused backup code, which is then used up. Returns `:ok`,
  `{:ok, :backup_code}` or `{:error, :invalid_code}`.
  """
  def verify_code(%User{} = user, code) when is_binary(code) do
    code = normalize(code)

    cond do
      String.match?(code, ~r/^\d{6}$/) -> verify_totp(user, code)
      code != "" -> use_backup_code(user, code)
      true -> {:error, :invalid_code}
    end
  end

  def verify_code(_user, _code), do: {:error, :invalid_code}

  defp normalize(code), do: code |> String.replace(~r/[\s-]/, "") |> String.downcase()

  defp verify_totp(user, code) do
    with %Totp{} = totp <- Repo.get_by(Totp, user_id: user.id),
         true <- totp_valid?(totp.secret, code, totp.last_used_at),
         # Two logins racing with one code: only the first moves it on.
         {1, _} <-
           Repo.update_all(unchanged(totp), set: [last_used_at: DateTime.utc_now(:second)]) do
      :ok
    else
      _invalid -> {:error, :invalid_code}
    end
  end

  defp unchanged(%Totp{id: id, last_used_at: nil}),
    do: from(t in Totp, where: t.id == ^id and is_nil(t.last_used_at))

  defp unchanged(%Totp{id: id, last_used_at: at}),
    do: from(t in Totp, where: t.id == ^id and t.last_used_at == ^at)

  # This period's code or the last one's (a phone's clock may lag), never
  # one from the period of the last code used, or before.
  defp totp_valid?(secret, code, since) do
    now = System.os_time(:second)
    Enum.any?([now, now - 30], &NimbleTOTP.valid?(secret, code, time: &1, since: since))
  end

  ## Backup codes

  @doc "How many unused backup codes `user` has."
  def backup_codes_left(%User{id: id}) do
    Repo.aggregate(from(b in BackupCode, where: b.user_id == ^id and is_nil(b.used_at)), :count)
  end

  @doc "Replaces `user`'s backup codes with new ones (two-factor must be on): `{:ok, codes}`."
  def regenerate_backup_codes(%User{} = user) do
    if enabled?(user) do
      Repo.transact(fn ->
        delete_backup_codes(user)
        {:ok, insert_backup_codes(user)}
      end)
    else
      {:error, :not_enabled}
    end
  end

  defp insert_backup_codes(user) do
    codes = for _ <- 1..@backup_codes, do: new_backup_code()
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      BackupCode,
      Enum.map(codes, &%{user_id: user.id, code_hash: hash(&1), inserted_at: now})
    )

    codes
  end

  # 80 random bits, as four groups of four base32 characters.
  defp new_backup_code do
    10
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  defp hash(code), do: :sha256 |> :crypto.hash(normalize(code)) |> Base.encode16(case: :lower)

  defp use_backup_code(user, code) do
    now = DateTime.utc_now(:second)

    case Repo.update_all(
           from(b in BackupCode,
             where: b.user_id == ^user.id and b.code_hash == ^hash(code) and is_nil(b.used_at)
           ),
           set: [used_at: now]
         ) do
      {1, _} -> {:ok, :backup_code}
      {_none, _} -> {:error, :invalid_code}
    end
  end

  defp delete_backup_codes(user),
    do: Repo.delete_all(from(b in BackupCode, where: b.user_id == ^user.id))

  ## Security keys

  @doc "`user`'s security keys (not passkeys, see `Firefly.Passkeys`), oldest first."
  def credentials(%User{id: id}) do
    Repo.all(from(c in Credential, where: c.user_id == ^id and not c.passkey, order_by: c.id))
  end

  @doc "Saves a registered security key (attrs from `Firefly.WebAuthn.register/2`) as `name`."
  def add_credential(%User{} = user, attrs, name) do
    result =
      %Credential{user_id: user.id}
      |> Ecto.Changeset.change(attrs)
      |> Credential.name_changeset(%{name: name})
      |> Ecto.Changeset.unique_constraint(:credential_id, message: "is registered already")
      |> Repo.insert()

    with {:ok, credential} <- result do
      if backup_codes_left(user) == 0,
        do: {:ok, credential, insert_backup_codes(user)},
        else: {:ok, credential, []}
    end
  end

  @doc "Renames one of `user`'s security keys."
  def rename_credential(%User{} = user, id, name) do
    case Repo.get_by(Credential, id: id, user_id: user.id, passkey: false) do
      nil -> {:error, :not_found}
      credential -> credential |> Credential.name_changeset(%{name: name}) |> Repo.update()
    end
  end

  @doc "Removes one of `user`'s security keys, confirmed like `disable_totp/2`."
  def delete_credential(%User{} = user, id, confirmation) do
    with :ok <- confirm(user, confirmation) do
      Repo.delete_all(
        from(c in Credential, where: c.id == ^id and c.user_id == ^user.id and not c.passkey)
      )

      unless enabled?(user), do: delete_backup_codes(user)
      :ok
    end
  end

  ## Staff

  @doc "Turns off every second factor of `user`, as `admin` (staff-logged)."
  def reset(%User{} = user, %User{} = admin) do
    Repo.transact(fn ->
      for schema <- [Totp, BackupCode],
          do: Repo.delete_all(from(r in schema, where: r.user_id == ^user.id))

      # Passkeys stay: they're a way in of their own, not a second factor.
      Repo.delete_all(from(c in Credential, where: c.user_id == ^user.id and not c.passkey))

      StaffLog.record(admin, "user.reset_two_factor", user, %{username: user.username})
      {:ok, user}
    end)
  end

  @doc "A message for an error from this module."
  def message(:invalid_code), do: "That code isn't right (or was used already)."
  def message(:not_enabled), do: "Turn on two-factor authentication first."
  def message(:not_found), do: "That security key isn't yours."

  @doc "The export of `user`'s second factors: what's set up, never the secrets."
  def export(%User{} = user) do
    %{
      authenticator_app: totp?(user),
      backup_codes_left: backup_codes_left(user),
      security_keys:
        for(c <- credentials(user), do: Map.take(c, [:name, :inserted_at, :last_used_at]))
    }
  end
end
