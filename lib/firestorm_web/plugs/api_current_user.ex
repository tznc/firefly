defmodule FirestormWeb.Web.Plugs.ApiCurrentUser do
  @moduledoc """
  A `Plug` to assign `:current_user` based on the authorization header containing a user's api token
  """

  import Plug.Conn
  alias FirestormWeb.Forums

  def init(options), do: options

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      [] ->
        conn

      [authorization | _] ->
        api_token =
          authorization
          |> String.replace("Bearer ", "")

        case Forums.get_user_by_api_token(api_token) do
          %{deleted_at: nil} = user ->
            conn
            |> assign(:current_user, user)

          _missing_or_deleted ->
            conn
        end
    end
  end
end
