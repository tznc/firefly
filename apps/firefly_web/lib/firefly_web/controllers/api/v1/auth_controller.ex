defmodule FireflyWeb.Api.V1.AuthController do
  @moduledoc """
  Trades a username and password for a new API key with every scope
  (`api_token`; see `Firefly.Accounts.ApiKeys`), listed in the member's
  Settings > API keys to revoke. Users with two-factor authentication
  also send a current code (`user[otp]`, an authenticator or backup code;
  see `Firefly.Accounts.TwoFactor`). Errors are problem details.
  """
  use FireflyWeb, :controller
  alias Firefly.{Accounts, RateLimit, Security}
  alias Firefly.Accounts.{ApiKeys, TwoFactor, User}
  alias Firefly.Moderation.Penalties
  alias FireflyWeb.Api.Problem

  def identity(conn, %{"user" => %{} = user_params}) do
    Process.sleep(Security.login_delay(user_params["username"], conn.remote_ip))

    with true <- Firefly.Accounts.Auth.password_login?() || {:error, :sso_only},
         :ok <- RateLimit.check_login(user_params["username"], conn.remote_ip),
         {:ok, user} <-
           Accounts.authenticate_by_password(user_params["username"], user_params["password"]),
         true <- not User.suspended?(user) || {:suspended, user},
         :ok <- second_factor(user, user_params["otp"]),
         {:ok, _key, token} <- ApiKeys.create_login_key(user) do
      Security.record("login.success", user, %{method: "api"})
      json(conn, %{"data" => %{"api_token" => token}})
    else
      {:suspended, user} ->
        Problem.send(conn, 403, Penalties.suspended_message(user))

      {:error, :sso_only} ->
        Problem.send(conn, 403, "Password login is off.")

      {:error, :two_factor} ->
        Problem.send(conn, 401, "Two-factor code required.", %{two_factor: true})

      {:error, :rate_limited} ->
        Problem.send(conn, 429, RateLimit.message())

      {:error, _reason} ->
        Security.login_failed("login.failure", user_params["username"], %{method: "api"})
        Problem.send(conn, 401, "Login failed.")
    end
  end

  def identity(conn, _params),
    do: Problem.send(conn, 422, "user[username] and user[password] are required.")

  defp second_factor(user, otp) do
    cond do
      not TwoFactor.enabled?(user) -> :ok
      RateLimit.check_two_factor(user) != :ok -> {:error, :rate_limited}
      TwoFactor.verify_code(user, otp) in [:ok, {:ok, :backup_code}] -> :ok
      true -> {:error, :two_factor}
    end
  end
end
