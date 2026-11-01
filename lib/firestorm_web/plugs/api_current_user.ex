defmodule FirestormWeb.Web.Plugs.ApiCurrentUser do
  @moduledoc """
  A `Plug` to assign `:current_user` based on the authorization header
  containing a user's api token. Deleted and suspended users' tokens are
  rejected.
  """

  import Plug.Conn
  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.User

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
          %{deleted_at: nil} = user -> assign_unless_suspended(conn, user)
          _missing_or_deleted -> conn
        end
    end
  end

  defp assign_unless_suspended(conn, user),
    do: if(User.suspended?(user), do: conn, else: assign(conn, :current_user, user))
end
