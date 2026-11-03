defmodule FireflyWeb.Api.Helpers do
  @moduledoc """
  What every API controller (`FireflyWeb.Api.V1.*`) shares: scope and
  login checks as function plugs, the same permission checks the web
  interface uses, and the response envelope (`{"data": ...}`).

      plug :require_scope, "read"
      plug :require_scope, "topics:write" when action in [:create]

  A request without a key acts as a visitor: it may read what visitors
  may (the `read` scope check passes), and nothing else. A request with a
  key needs the scope as well as the user's permission.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Firefly.Accounts.ApiKeys
  alias FireflyWeb.Api.Problem

  @doc "Function plug: the key must have `scope` (any request may `read`)."
  def require_scope(%{assigns: %{api_key: key}} = conn, scope) when not is_nil(key) do
    if ApiKeys.allows?(key, scope),
      do: conn,
      else: Problem.send(conn, 403, "This API key doesn't have the #{scope} scope.")
  end

  def require_scope(conn, "read"), do: conn
  def require_scope(conn, _scope), do: require_user(conn, [])

  @doc "Function plug: the request must be made with a user's key."
  def require_user(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  def require_user(conn, _opts) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="firefly"))
    |> Problem.send(401, "An API key is required (Authorization: Bearer <key>).")
  end

  @doc "`:ok` when `user` may take `action` (see `Firefly.Discussion.Policy`), else `{:error, :forbidden}`."
  def permit(user, action, resource \\ %{}) do
    if FireflyWeb.Authorization.can?(user, action, resource), do: :ok, else: {:error, :forbidden}
  end

  @doc "Renders `data` in the envelope, with `status` (default 200)."
  def ok(conn, data, status \\ 200), do: conn |> put_status(status) |> json(%{data: data})

  @doc "Answers `204 No Content`."
  def no_content(conn), do: send_resp(conn, 204, "")

  @doc "The request's user (nil for visitors)."
  def current_user(conn), do: conn.assigns[:current_user]

  @doc "The notification level in `params` (`{:ok, level}`), or a 422 error."
  def notification_level(params) do
    levels = Firefly.Notifications.Subscriptions.levels()

    if params["level"] in levels,
      do: {:ok, params["level"]},
      else: {:error, "level must be one of: #{Enum.join(levels, ", ")}"}
  end

  @doc "An integer id from a path or body parameter, or nil."
  def int(value) when is_integer(value), do: value

  def int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _other -> nil
    end
  end

  def int(_value), do: nil
end
