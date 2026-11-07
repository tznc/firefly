defmodule FireflyWeb.StaffController do
  @moduledoc """
  The parts of the staff admin that change the session: impersonation
  (an admin seeing the site as a member, see `Firefly.Accounts.UserAdmin`)
  and sending the old `/admin` URLs to `/staff`.

  Impersonating keeps the admin's own session and puts the member's id in
  it (`impersonate_id`, see `FireflyWeb.Session`), so every page shows a
  banner to stop (see `FireflyWeb.Layouts.impersonation_banner/1`), and
  stopping removes it. Both are staff-logged. Admins can't
  impersonate staff, deleted or suspended accounts, or themselves (see
  the `:impersonate` policy).
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts
  alias Firefly.Accounts.UserAdmin

  @doc "Starts seeing the site as the member with `id` (behind the `:admin` pipeline)."
  def impersonate(conn, %{"id" => id}) do
    admin = conn.assigns.current_user
    user = Accounts.get_user(id)

    if user && FireflyWeb.Authorization.can?(admin, :impersonate, user) do
      UserAdmin.impersonated(admin, user)

      conn
      |> configure_session(renew: true)
      |> put_session(:impersonate_id, user.id)
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
    %{current_user: user, impersonator: admin} = conn.assigns

    cond do
      admin ->
        UserAdmin.stopped_impersonating(admin, user)

        conn
        |> configure_session(renew: true)
        |> delete_session(:impersonate_id)
        |> put_flash(:info, gettext("You're yourself again."))
        |> redirect(to: ~p"/staff/users/#{user.id}")

      # The member can't be seen as any more (deleted, suspended).
      user && get_session(conn, :impersonate_id) ->
        conn
        |> delete_session(:impersonate_id)
        |> redirect(to: ~p"/staff/users")

      # Not impersonating: just log out.
      true ->
        conn
        |> FireflyWeb.Session.stop()
        |> redirect(to: ~p"/")
    end
  end

  @doc "The old admin at `/admin` (and its pages) is the staff admin now."
  def admin_moved(conn, _params), do: redirect(conn, to: ~p"/staff")

  @doc "The plugins list is the packages list now."
  def plugins_moved(conn, _params), do: redirect(conn, to: ~p"/staff/packages")
end
