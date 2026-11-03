defmodule FireflyWeb.Api.V1.AuthController do
  @moduledoc """
  Trades a username and password for the user's API token. Users with
  two-factor authentication also send a current code (`user[otp]`, an
  authenticator or backup code; see `Firefly.Accounts.TwoFactor`).
  """
  use FireflyWeb, :controller
  alias Firefly.{Accounts, RateLimit}
  alias Firefly.Accounts.{TwoFactor, User}
  alias Firefly.Moderation.Penalties

  def identity(conn, %{"user" => user_params}) do
    with true <- Firefly.Accounts.Auth.password_login?() || {:error, :sso_only},
         :ok <- RateLimit.check_login(user_params["username"], conn.remote_ip),
         {:ok, user} <-
           Accounts.authenticate_by_password(user_params["username"], user_params["password"]),
         true <- not User.suspended?(user) || {:suspended, user},
         :ok <- second_factor(user, user_params["otp"]) do
      json(conn, %{"data" => %{"api_token" => user.api_token}})
    else
      {:suspended, user} ->
        conn |> put_status(:forbidden) |> json(%{"error" => Penalties.suspended_message(user)})

      {:error, :sso_only} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "Password login is off"})

      {:error, :two_factor} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{"error" => "Two-factor code required", "two_factor" => true})

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => RateLimit.message()})

      {:error, _reason} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "Login failed"})
    end
  end

  defp second_factor(user, otp) do
    cond do
      not TwoFactor.enabled?(user) -> :ok
      RateLimit.check_two_factor(user) != :ok -> {:error, :rate_limited}
      TwoFactor.verify_code(user, otp) in [:ok, {:ok, :backup_code}] -> :ok
      true -> {:error, :two_factor}
    end
  end
end
