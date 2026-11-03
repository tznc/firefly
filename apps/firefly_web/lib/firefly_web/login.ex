defmodule FireflyWeb.Login do
  @moduledoc """
  Finishing a login in a controller, however the user proved who they are
  (a password, a social login, OpenID Connect, DiscourseConnect): suspended
  users are told why (only once they've proven who they are); users with
  two-factor authentication (see `Firefly.Accounts.TwoFactor.required?/2`) go
  on to give their second factor (`FireflyWeb.TwoFactorController`),
  with the login waiting in the session for 10 minutes; anyone else gets a
  fresh session.
  """

  use FireflyWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Firefly.Repo
  alias Firefly.Accounts.{TwoFactor, WebAuthn}
  alias Firefly.Moderation.Penalties
  alias Firefly.Accounts.User

  @pending_seconds 600

  @doc """
  Logs `user` in after they proved who they are by `method` (`:password`,
  `:sso`, `:magic_link`, `:passkey`) and sends them to `to` (a path on this
  site), asks for their second factor, or sends them back to
  `failure_path` if they're suspended.
  """
  def complete(conn, %User{} = user, failure_path, method, to \\ "/") do
    cond do
      User.suspended?(user) -> fail(conn, failure_path, Penalties.suspended_message(user))
      TwoFactor.required?(user, method) -> ask_second_factor(conn, user)
      true -> log_in(conn, user, "Successfully authenticated.", to)
    end
  end

  @doc "`path` if it's a path on this site (not another site's URL), else the home page."
  def local_path("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: "/", else: path
  end

  def local_path(_path), do: "/"

  defp ask_second_factor(conn, user) do
    conn
    |> configure_session(renew: true)
    |> delete_session(:current_user)
    |> put_session(:two_factor, %{"user_id" => user.id, "at" => System.system_time(:second)})
    |> put_key_challenge(user)
    |> redirect(to: ~p"/login/two-factor")
  end

  @doc """
  Keeps a fresh security key challenge in the session for the pending
  login of `user` (none if they have no keys).
  """
  def put_key_challenge(conn, user) do
    case TwoFactor.credentials(user) do
      [] ->
        delete_session(conn, :two_factor_challenge)

      credentials ->
        {challenge, _options} = WebAuthn.authentication(credentials)
        put_session(conn, :two_factor_challenge, WebAuthn.to_session(challenge))
    end
  end

  @doc "The user whose login waits for a second factor (from `session`), or nil."
  def pending_user(%{"two_factor" => %{"user_id" => id, "at" => at}}) do
    if System.system_time(:second) - at < @pending_seconds, do: Repo.get(User, id)
  end

  def pending_user(_session), do: nil

  @doc """
  Logs `user` in: a fresh session, any pending second-factor step gone,
  and `notice` (or a welcome) to show at `to`.
  """
  def log_in(conn, user, notice \\ "Successfully authenticated.", to \\ "/") do
    conn
    |> configure_session(renew: true)
    |> delete_session(:two_factor)
    |> delete_session(:two_factor_challenge)
    |> put_session(:current_user, user.id)
    |> put_session(:live_socket_id, FireflyWeb.Session.live_socket_id(user))
    |> put_flash(:info, notice)
    |> redirect(to: local_path(to))
  end

  @doc "Sends the browser back to `path` with `reason` (a message or a changeset)."
  def fail(conn, path, reason) do
    conn
    |> put_flash(:error, error_message(reason))
    |> redirect(to: path)
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(&FireflyWeb.CoreComponents.translate_error/1)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)

    "Login unsuccessful: #{details}"
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(_reason), do: "Login unsuccessful"
end
