defmodule FireflyWeb.StaffController do
  @moduledoc """
  The parts of the staff admin that change the session: impersonation
  (an admin seeing the site as a member, see `Firefly.Accounts.UserAdmin`)
  and sending the old `/admin` URLs to `/staff`.

  Impersonating keeps the admin's id in the session (`impersonator_id`)
  next to the member's (`current_user`), so every page shows a banner to
  stop (see `FireflyWeb.Layouts.impersonation_banner/1`), and stopping
  restores the admin's session. Both are staff-logged. Admins can't
  impersonate staff, deleted or suspended accounts, or themselves (see
  the `:impersonate` policy).
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts
  alias Firefly.Accounts.UserAdmin
  alias FireflyWeb.Session

  @doc "Starts seeing the site as the member with `id` (behind the `:admin` pipeline)."
  def impersonate(conn, %{"id" => id}) do
    admin = conn.assigns.current_user
    user = Accounts.get_user(id)

    if user && FireflyWeb.Authorization.can?(admin, :impersonate, user) do
      UserAdmin.impersonated(admin, user)

      conn
      |> configure_session(renew: true)
      |> put_session(:current_user, user.id)
      |> put_session(:impersonator_id, admin.id)
      |> put_session(:live_socket_id, Session.live_socket_id(user))
      |> put_flash(
        :info,
        gettext("You're seeing the site as @%{username}.", username: user.username)
      )
      |> redirect(to: ~p"/")
    else
      conn
      |> put_flash(:error, gettext("You can't impersonate that account."))
      |> redirect(to: ~p"/staff/users")
    end
  end

  @doc "Stops impersonating: the admin's own session again, back on the member's admin page."
  def stop_impersonating(conn, _params) do
    admin = Session.user_from_id(get_session(conn, :impersonator_id))
    user = conn.assigns.current_user

    if admin && Accounts.admin?(admin) do
      if user, do: UserAdmin.stopped_impersonating(admin, user)

      conn
      |> configure_session(renew: true)
      |> delete_session(:impersonator_id)
      |> put_session(:current_user, admin.id)
      |> put_session(:live_socket_id, Session.live_socket_id(admin))
      |> put_flash(:info, gettext("You're yourself again."))
      |> redirect(to: if(user, do: ~p"/staff/users/#{user.id}", else: ~p"/staff/users"))
    else
      # Not impersonating (or that admin is gone): just log out.
      conn
      |> configure_session(drop: true)
      |> redirect(to: ~p"/")
    end
  end

  @doc "The old admin at `/admin` (and its pages) is the staff admin now."
  def admin_moved(conn, _params), do: redirect(conn, to: ~p"/staff")
end
