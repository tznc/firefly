defmodule FirestormWeb.Web.Plugs.RequireApiUser do
  @moduledoc """
  Halts API requests with 401 unless `ApiCurrentUser` found a user for the
  bearer token.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(options), do: options

  def call(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(:unauthorized)
    |> json(%{"error" => "Authentication required"})
    |> halt()
  end
end
