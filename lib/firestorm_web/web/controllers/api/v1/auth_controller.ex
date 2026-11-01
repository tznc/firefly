defmodule FirestormWeb.Web.Api.V1.AuthController do
  use FirestormWeb.Web, :controller
  alias FirestormWeb.{Forums, RateLimit}

  def identity(conn, %{"user" => user_params}) do
    with :ok <- RateLimit.check_login(user_params["username"], conn.remote_ip),
         {:ok, user} <-
           Forums.authenticate_by_password(user_params["username"], user_params["password"]) do
      json(conn, %{"data" => %{"api_token" => user.api_token}})
    else
      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => RateLimit.message()})

      {:error, _reason} ->
        conn |> put_status(:unauthorized) |> json(%{"error" => "Login failed"})
    end
  end
end
