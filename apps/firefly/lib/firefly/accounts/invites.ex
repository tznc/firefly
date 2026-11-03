defmodule Firefly.Accounts.Invites do
  @moduledoc """
  Invitations to join, as in Discourse. Members at the
  `min_trust_to_invite` trust level (admins always) invite someone by
  email (one person; the email carries the link) or make a link up to
  `max_uses` people can use, optionally only with an address at one
  domain. Invites expire after `invite_expiry_days`, and their maker (or an
  admin) can revoke them or resend an email invite. Making and resending
  them count against the `:invite` rate limit.

  Staff can also have an invite add whoever redeems it to a group and send
  them to a thread they may read. Redeeming one creates the account even
  while only invited people may join (the `invite_only` site setting; it
  still needs `allow_registrations`), with a password or a social or
  single sign-on login (see `Firefly.Accounts.Auth.login/2`). An account
  made from an email invite has that address, confirmed: the invite proved
  it. Members already signed in can redeem a link too, to join its group.
  The inviter is notified (`invite_redeemed`).
  """

  import Ecto.Query
  import Ecto.Changeset, only: [add_error: 3, put_change: 3, change: 2]

  alias Firefly.{
    Accounts,
    Discussion,
    Mailer,
    Notifications,
    RateLimit,
    Repo,
    SiteSettings,
    TrustLevels,
    URLs
  }

  alias Firefly.Accounts.{Invite, InviteRedemption, User}
  alias Firefly.Discussion.Thread
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Notifications.Emails

  require Logger

  @preloads [:invited_by, :role, :thread, redemptions: :user]

  @doc "Whether `user` may invite people (the `min_trust_to_invite` setting; admins always)."
  def may_invite?(%User{} = user), do: TrustLevels.allowed?(user, "min_trust_to_invite")
  def may_invite?(nil), do: false

  @doc "Whether `user` may revoke or resend `invite`: its maker, and admins."
  def may_manage?(%User{id: id}, %Invite{invited_by_id: id}), do: true
  def may_manage?(%User{} = user, %Invite{}), do: Accounts.admin?(user)

  @doc "A changeset for the invite form."
  def change_invite(attrs \\ %{}), do: Invite.changeset(%Invite{}, attrs)

  @doc """
  Makes an invite from `inviter`. `attrs` (string keys): `email` (an email
  invite, sent at once) or `max_uses` and `domain` (a link), and, for
  admins, `role_id` (a group to join) and `thread` (a thread's id or link
  to land on). Errors: `:not_allowed`, `:rate_limited` or a changeset.
  """
  def create(%User{} = inviter, attrs) do
    with :ok <- if(may_invite?(inviter), do: :ok, else: {:error, :not_allowed}),
         :ok <- RateLimit.check(:invite, inviter.id),
         {:ok, invite} <- insert(inviter, attrs) do
      invite = Repo.preload(invite, @preloads)
      {:ok, if(Invite.email?(invite), do: send_email(invite), else: invite)}
    end
  end

  defp insert(inviter, attrs) do
    %Invite{invited_by_id: inviter.id, key: new_key(), expires_at: expiry()}
    |> Invite.changeset(attrs)
    |> validate_new_address()
    |> put_extras(inviter, attrs)
    |> Repo.insert()
  end

  defp new_key, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp expiry,
    do: DateTime.add(DateTime.utc_now(:second), SiteSettings.get("invite_expiry_days"), :day)

  defp validate_new_address(changeset) do
    email = Ecto.Changeset.get_change(changeset, :email)

    if email && Repo.exists?(from(u in User, where: fragment("lower(?)", u.email) == ^email)),
      do: add_error(changeset, :email, "already has an account"),
      else: changeset
  end

  # Groups and landing threads are for staff to set.
  defp put_extras(changeset, inviter, attrs) do
    if Accounts.admin?(inviter) do
      changeset
      |> put_role(attrs["role_id"])
      |> put_thread(inviter, attrs["thread"])
    else
      changeset
    end
  end

  defp put_role(changeset, blank) when blank in [nil, ""], do: changeset

  defp put_role(changeset, role_id) do
    case Integer.parse(to_string(role_id)) do
      {id, ""} -> if Repo.get(Role, id), do: put_change(changeset, :role_id, id), else: changeset
      _ -> add_error(changeset, :role_id, "is not a group")
    end
  end

  defp put_thread(changeset, _inviter, blank) when blank in [nil, ""], do: changeset

  defp put_thread(changeset, inviter, input) do
    with [id] <- Regex.run(~r{(?:threads/)?(\d+)/*$}, String.trim(input), capture: :all_but_first),
         %Thread{} = thread <- Repo.get(Thread, String.to_integer(id)),
         true <- Bodyguard.permit?(Discussion, :view_thread, inviter, thread) do
      put_change(changeset, :thread_id, thread.id)
    else
      _ -> add_error(changeset, :thread_id, "give a thread's link or id")
    end
  end

  defp send_email(invite) do
    case invite |> Emails.invite(URLs.invite_url(invite.key)) |> Mailer.deliver_now() do
      {:ok, _email} -> Repo.update!(change(invite, emailed_at: DateTime.utc_now(:second)))
      {:error, error} -> email_failed(invite, error)
    end
  rescue
    error -> email_failed(invite, error)
  end

  # The invite is made; its maker can resend it.
  defp email_failed(invite, error) do
    Logger.error("Invite email #{invite.id} failed: #{inspect(error)}")
    invite
  end

  @doc """
  Sends an email invite again as `actor`, starting its time over. Errors:
  `:not_allowed`, `:not_email`, `:revoked`, `:used_up`, `:rate_limited`.
  """
  def resend(%Invite{} = invite, %User{} = actor) do
    cond do
      not may_manage?(actor, invite) -> {:error, :not_allowed}
      not Invite.email?(invite) -> {:error, :not_email}
      Invite.problem(invite) in [:revoked, :used_up] -> {:error, Invite.problem(invite)}
      true -> with :ok <- RateLimit.check(:invite, actor.id), do: {:ok, renew_and_send(invite)}
    end
  end

  defp renew_and_send(invite),
    do:
      invite
      |> change(expires_at: expiry())
      |> Repo.update!()
      |> Repo.preload(@preloads)
      |> send_email()

  @doc "Revokes `invite` as `actor` (its maker or an admin)."
  def revoke(%Invite{} = invite, %User{} = actor) do
    if may_manage?(actor, invite),
      do: {:ok, Repo.update!(change(invite, revoked_at: DateTime.utc_now(:second)))},
      else: {:error, :not_allowed}
  end

  @doc "`user`'s invites, newest first, with who redeemed them."
  def list_for(%User{id: id}) do
    Invite
    |> where([i], i.invited_by_id == ^id)
    |> order_by(desc: :id)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc "Everyone's invites (for staff), newest first: the latest 200."
  def list_all do
    Invite
    |> order_by(desc: :id)
    |> limit(200)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc "The invite with `key`, or nil."
  def get_by_key(key) when is_binary(key),
    do: Invite |> preload(^@preloads) |> Repo.get_by(key: key)

  def get_by_key(_key), do: nil

  @doc "The invite with `id`, or nil."
  def get(id), do: Repo.get(Invite, id)

  ## Redeeming

  @doc """
  Creates an account from the registration form's `attrs` through
  `invite`: with an email invite, its address, confirmed. Errors: a
  changeset, `:registration_closed`, or a reason from `use_invite/2`.
  """
  def register(%Invite{} = invite, attrs) do
    attrs = if invite.email, do: Map.put(attrs, "email", invite.email), else: attrs

    result =
      Repo.transact(fn ->
        with :ok <- open(),
             {:ok, user} <- Accounts.register_invited_user(attrs, Invite.email?(invite)),
             {:ok, _invite} <- use_invite(invite, user),
             do: {:ok, user}
      end)

    with {:ok, user} <- result do
      redeemed(invite, user)
      {:ok, user}
    end
  end

  @doc "Whether invited people may join (the `allow_registrations` setting)."
  def open,
    do: if(SiteSettings.get("allow_registrations"), do: :ok, else: {:error, :registration_closed})

  @doc "Redeems `invite` for an existing member, `user` (to join its group)."
  def redeem(%Invite{} = invite, %User{} = user) do
    with {:ok, invite} <- Repo.transact(fn -> use_invite(invite, user) end) do
      redeemed(invite, user)
      {:ok, invite}
    end
  end

  @doc """
  The database part of redeeming `invite` for `user`, for callers that
  create the user in the same transaction (call `redeemed/2` once it
  commits). Errors: `:revoked`, `:expired`, `:used_up`, `:wrong_email`,
  `:wrong_domain`, `:already_redeemed`.
  """
  def use_invite(%Invite{id: id}, %User{} = user) do
    invite = Invite |> lock("FOR UPDATE") |> Repo.get!(id)

    cond do
      reason = Invite.problem(invite) ->
        {:error, reason}

      (fits = address_fits(invite, user)) != :ok ->
        fits

      Repo.exists?(redemption(invite, user)) ->
        {:error, :already_redeemed}

      true ->
        Repo.insert!(%InviteRedemption{invite_id: invite.id, user_id: user.id})
        join_group(invite, user)
        {:ok, Repo.update!(change(invite, uses: invite.uses + 1))}
    end
  end

  defp redemption(invite, user),
    do: where(InviteRedemption, [r], r.invite_id == ^invite.id and r.user_id == ^user.id)

  defp address_fits(%Invite{email: nil, domain: nil}, _user), do: :ok

  defp address_fits(%Invite{email: nil, domain: domain}, %User{email: email}) do
    if is_binary(email) and String.ends_with?(String.downcase(email), "@" <> domain),
      do: :ok,
      else: {:error, :wrong_domain}
  end

  defp address_fits(%Invite{email: invited}, %User{email: email}) do
    if is_binary(email) and String.downcase(email) == invited,
      do: :ok,
      else: {:error, :wrong_email}
  end

  defp join_group(%Invite{role_id: nil}, _user), do: :ok

  defp join_group(%Invite{role_id: role_id}, user) do
    Repo.insert!(%RoleMembership{role_id: role_id, user_id: user.id}, on_conflict: :nothing)

    :ok
  end

  @doc "Tells the inviter `user` redeemed `invite` (after `use_invite/2` committed)."
  def redeemed(%Invite{} = invite, %User{} = user) do
    invite = Repo.preload(invite, :invited_by)

    {:ok, _} =
      Notifications.notify(invite.invited_by, %{
        kind: "invite_redeemed",
        subject: "@#{user.username} accepted your invitation",
        body: "@#{user.username} joined #{SiteSettings.get("title")} with your invitation.",
        url: URLs.user_url(user)
      })

    :ok
  end

  @doc "Where someone who redeemed `invite` goes next: its thread, or the home page."
  def destination(%Invite{thread: %Thread{} = thread}),
    do: URI.parse(URLs.thread_url(thread)).path

  def destination(%Invite{}), do: "/"

  @doc "A message for an error from this module."
  def message(:not_allowed), do: "You can't do that with invitations."
  def message(:not_email), do: "Only email invitations can be resent."
  def message(:revoked), do: "This invitation was revoked."
  def message(:expired), do: "This invitation has expired."
  def message(:used_up), do: "This invitation has been used up."
  def message(:wrong_email), do: "This invitation is for another email address."
  def message(:wrong_domain), do: "This invitation is for email addresses at another domain."
  def message(:already_redeemed), do: "You've already used this invitation."
  def message(:registration_closed), do: "New registrations are closed."
  def message(:rate_limited), do: RateLimit.message()
end
