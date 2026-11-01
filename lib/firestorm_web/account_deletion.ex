defmodule FirestormWeb.AccountDeletion do
  @moduledoc """
  Self-serve account deletion.

  Forum content isn't deleted with the account: the user row is anonymized
  in place into a placeholder (`deleted-user-<id>`, no name, email, password,
  GitHub link or profile), so posts, threads, revisions and private messages
  keep an author without saying who it was. Everything else personal goes:
  roles, read positions, notification levels, notifications, likes, post
  views and conversation memberships. Other users' notifications that named
  the user ("@ada replied in ...") and the staff log name the placeholder
  instead (see `FirestormWeb.StaffLog.scrub_user/2`).

  Every way in is closed: sessions resolve deleted users to nobody (see
  `FirestormWeb.Web.Session`), open LiveViews are disconnected, the API
  token is replaced, and password reset and confirmation links no longer
  match (they're bound to the email).
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo, StaffLog}
  alias FirestormWeb.Web.Session
  alias FirestormWeb.Forums.{ConversationParticipant, Notification, Role, RoleMembership, User}

  @doc """
  Checks the confirmation: the password for password accounts, the username
  (any case) for accounts without one (GitHub logins).
  """
  def confirmed?(%User{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password),
      do: Bcrypt.verify_pass(password, hash)

  def confirmed?(%User{password_hash: hash}, _password) when is_binary(hash),
    do: Bcrypt.no_user_verify()

  def confirmed?(%User{username: username}, typed) when is_binary(typed),
    do: String.downcase(String.trim(typed)) == String.downcase(username)

  def confirmed?(%User{}, _typed), do: false

  @doc """
  Deletes the account after `confirmed?/2`. The last admin can't delete
  themselves.
  """
  def delete_account(%User{} = user, confirmation) do
    cond do
      User.deleted?(user) -> {:error, :deleted}
      not confirmed?(user, confirmation) -> {:error, :unconfirmed}
      true -> anonymize(user)
    end
  end

  def message(:unconfirmed), do: "That doesn't match. Your account was not deleted."

  def message(:last_admin),
    do: "You're the only admin. Make someone else an admin before deleting your account."

  def message(:deleted), do: "This account is already deleted."

  def message(_failed), do: "Your account could not be deleted. Please try again."

  # Runs inside the deletion transaction with the admin memberships locked,
  # so two admins deleting at once can't both see the other one remaining.
  defp last_admin?(user) do
    admins =
      RoleMembership
      |> join(:inner, [m], r in Role, on: r.id == m.role_id and r.name == "admin")
      |> join(:inner, [m], u in User, on: u.id == m.user_id and is_nil(u.deleted_at))
      |> select([m], m.user_id)
      |> lock("FOR UPDATE")
      |> Repo.all()
      |> Enum.uniq()

    user.id in admins and length(admins) <= 1
  end

  defp anonymize(%User{id: id} = user) do
    liked_post_ids =
      Repo.all(from(l in "forums_post_likes", where: l.user_id == ^id, select: l.post_id))

    result =
      Repo.transact(fn ->
        if last_admin?(user), do: Repo.rollback(:last_admin)

        for table <- ~w(forums_role_memberships forums_thread_reads forums_threads_watches
                        forums_categories_watches forums_tags_watches forums_post_likes
                        forums_posts_views),
            do: Repo.delete_all(from(r in table, where: r.user_id == ^id))

        Repo.delete_all(from(n in Notification, where: n.user_id == ^id))
        Repo.delete_all(from(p in ConversationParticipant, where: p.user_id == ^id))
        rename_in_notifications(user.username, User.deleted_username(id))
        StaffLog.scrub_user(user, User.deleted_username(id))

        user
        |> Ecto.Changeset.change(
          username: User.deleted_username(id),
          name: "Deleted user",
          email: nil,
          password_hash: nil,
          github_uid: nil,
          api_token: Ecto.UUID.generate(),
          confirmed_at: nil,
          bio: nil,
          website: nil,
          location: nil,
          email_notifications: false,
          allow_private_messages: false,
          hide_from_directory: true,
          deleted_at: DateTime.utc_now(:second)
        )
        |> Ecto.Changeset.unique_constraint(:username)
        |> Repo.update()
      end)

    with {:ok, deleted} <- result do
      # The likes are gone: their authors' unread "liked" notifications are
      # recounted (or removed when no likes remain).
      Forums.refresh_like_notifications(liked_post_ids)

      # Open LiveViews of this user (any browser) are disconnected; they come
      # back logged out.
      Session.reload_pages(deleted)
      {:ok, deleted}
    end
  end

  # Other users' notifications name the author in their stored subject
  # ("@ada replied in ..."); they now name the placeholder instead.
  defp rename_in_notifications(old, new) do
    pattern = "@" <> Regex.escape(old) <> "(?![A-Za-z0-9_-])"

    Repo.update_all(
      from(n in Notification,
        where: like(n.subject, ^"%@#{escape_like(old)}%"),
        update: [
          set: [
            subject: fragment("regexp_replace(?, ?, ?, 'g')", n.subject, ^pattern, ^"@#{new}")
          ]
        ]
      ),
      []
    )
  end

  defp escape_like(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
end
