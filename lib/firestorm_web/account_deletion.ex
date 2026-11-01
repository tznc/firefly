defmodule FirestormWeb.AccountDeletion do
  @moduledoc """
  Self-serve account deletion.

  Forum content isn't deleted with the account: the user row is anonymized
  in place into a placeholder (`deleted-user-<id>`, no name, email, password,
  GitHub link or profile), so posts, threads, revisions and private messages
  keep an author without saying who it was. Everything else personal goes:
  roles, read positions, notification levels, notifications, likes, post
  views and conversation memberships.

  Every way in is closed: sessions resolve deleted users to nobody (see
  `FirestormWeb.Web.Session`), open LiveViews are disconnected, the API
  token is replaced, and password reset and confirmation links no longer
  match (they're bound to the email).
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo}
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
      last_admin?(user) -> {:error, :last_admin}
      true -> anonymize(user)
    end
  end

  def message(:unconfirmed), do: "That doesn't match. Your account was not deleted."

  def message(:last_admin),
    do: "You're the only admin. Make someone else an admin before deleting your account."

  def message(:deleted), do: "This account is already deleted."

  defp last_admin?(user) do
    admins =
      RoleMembership
      |> join(:inner, [m], r in Role, on: r.id == m.role_id and r.name == "admin")
      |> join(:inner, [m], u in User, on: u.id == m.user_id and is_nil(u.deleted_at))
      |> select([m], count(m.user_id, :distinct))
      |> Repo.one()

    Forums.admin?(user) and admins <= 1
  end

  defp anonymize(%User{id: id} = user) do
    {:ok, deleted} =
      Repo.transact(fn ->
        for table <- ~w(forums_role_memberships forums_thread_reads forums_threads_watches
                        forums_categories_watches forums_tags_watches forums_post_likes
                        forums_posts_views),
            do: Repo.delete_all(from(r in table, where: r.user_id == ^id))

        Repo.delete_all(from(n in Notification, where: n.user_id == ^id))
        Repo.delete_all(from(p in ConversationParticipant, where: p.user_id == ^id))

        user
        |> Ecto.Changeset.change(
          username: "deleted-user-#{id}",
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
        |> Repo.update()
      end)

    # Open LiveViews of this user (any browser) are disconnected; they come
    # back logged out.
    FirestormWeb.Web.Endpoint.broadcast(Session.live_socket_id(deleted), "disconnect", %{})
    {:ok, deleted}
  end
end
