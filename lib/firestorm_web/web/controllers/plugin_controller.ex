defmodule FirestormWeb.Web.PluginController do
  @moduledoc """
  Plugins' HTTP surface outside LiveView (see `FirestormWeb.Plugins.UI`):
  their static assets for widget and page frames, served with a strict
  Content Security Policy; the widget SDK; and their inbound endpoints at
  `/api/plugins/:id/*path`.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.Plugins.UI

  @sdk_path "plugins/sdk/widget.js"
  @external_resource Path.join("priv", @sdk_path)

  @doc "A plugin asset."
  def asset(conn, %{"id" => id, "path" => path}) do
    case UI.asset(id, Enum.join(path, "/")) do
      {:ok, data} ->
        conn
        |> sandbox_headers()
        |> put_resp_content_type(MIME.from_path(Enum.join(path, "/")), nil)
        |> send_resp(200, data)

      :error ->
        send_resp(conn, 404, "Not found")
    end
  end

  @doc "The widget SDK (`Firefly.ready`, `Firefly.call`, `Firefly.resize`)."
  def sdk(conn, _params) do
    conn
    |> sandbox_headers()
    |> put_resp_content_type("text/javascript")
    |> send_resp(200, File.read!(Application.app_dir(:firestorm_web, ["priv", @sdk_path])))
  end

  defp sandbox_headers(conn) do
    conn
    |> put_resp_header("content-security-policy", UI.csp())
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-cache")
  end

  @max_body 100 * 1024

  @doc "An inbound request to a plugin's endpoint."
  def endpoint(conn, %{"id" => id, "path" => path}) do
    if request_too_large?(conn) do
      conn |> put_status(413) |> json(%{error: "the request body is over 100 KB"})
    else
      input = %{
        "method" => conn.method,
        "path" => "/" <> Enum.join(path, "/"),
        "query" => conn.query_params,
        "body" => conn.body_params
      }

      auth = %{
        secret: List.first(get_req_header(conn, "x-plugin-secret")),
        user: conn.assigns[:current_user]
      }

      caller = conn.remote_ip |> :inet.ntoa() |> to_string()
      {status, body} = UI.request(id, input, auth, caller)
      conn |> put_status(status) |> json(body)
    end
  end

  defp request_too_large?(conn) do
    case get_req_header(conn, "content-length") do
      [length | _] -> String.to_integer(length) > @max_body
      [] -> false
    end
  rescue
    ArgumentError -> true
  end
end
