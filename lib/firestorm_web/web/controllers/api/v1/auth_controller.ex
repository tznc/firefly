defmodule FirestormWeb.Web.Api.V1.AuthController do
  use FirestormWeb.Web, :controller
  alias FirestormWeb.{Forums, Penalties, RateLimit}
  alias FirestormWeb.Forums.User

  def identity(conn, %{"user" => user_params}) do
    with :ok <- RateLimit.check_login(user_params["username"], conn.remote_ip),
         {:ok, user} <-
           Forums.authenticate_by_password(user_params["username"], user_params["password"]),
         true <- not User.suspended?(user) || {:suspended, user} do
      json(conn, %{"data" => %{"api_token" => user.api_token}})
    else
      {:suspended, user} ->
        conn |> put_status(:forbidden) |> json(%{"error" => Penalties.suspended_message(user)})

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => RateLimit.message()})

      {:error, _reason} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "Login failed"})
    end
  end
end
