defmodule FireflyWeb.TwoFactorController do
  @moduledoc """
  The second step of a login with two-factor authentication (see
  `FireflyWeb.Login`): checks a code (authenticator or backup) or a
  security key's answer for the login waiting in the session, rate-limited
  per user, and logs in. A failed attempt goes back to the form with a new
  security key challenge.
  """
  use FireflyWeb, :controller

  alias Firefly.RateLimit
  alias Firefly.Accounts.{TwoFactor, WebAuthn}
  alias FireflyWeb.Login

  def create(conn, params) do
    attempt(conn, fn user -> code(user, params["code"]) end)
  end

  def key(conn, params) do
    attempt(conn, fn user ->
      credentials = TwoFactor.credentials(user)
      challenge = WebAuthn.from_session(get_session(conn, :two_factor_challenge), credentials)

      case challenge && WebAuthn.authenticate(challenge, credentials, params["key"] || %{}) do
        {:ok, _credential} -> :ok
        _invalid -> {:error, "Your security key wasn't accepted. Try again."}
      end
    end)
  end

  defp code(user, code) do
    case TwoFactor.verify_code(user, code) do
      :ok -> :ok
      {:ok, :backup_code} -> {:ok, backup_code_message(user)}
      {:error, reason} -> {:error, TwoFactor.message(reason)}
    end
  end

  defp backup_code_message(user) do
    case TwoFactor.backup_codes_left(user) do
      0 -> "You used your last backup code. Generate new ones in Settings > Security."
      left -> "You used a backup code: #{left} left."
    end
  end

  defp attempt(conn, check) do
    case Login.pending_user(get_session(conn)) do
      nil ->
        conn
        |> put_flash(:error, "Your login timed out. Log in again.")
        |> redirect(to: ~p"/login")

      user ->
        result =
          with :ok <- rate_limit(user), do: check.(user)

        finish(conn, user, result)
    end
  end

  defp rate_limit(user) do
    case RateLimit.check_two_factor(user) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, RateLimit.message()}
    end
  end

  defp finish(conn, user, :ok), do: Login.log_in(conn, user)

  defp finish(conn, user, {:ok, notice}), do: Login.log_in(conn, user, notice)

  defp finish(conn, user, {:error, message}) do
    conn
    |> Login.put_key_challenge(user)
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login/two-factor")
  end
end
