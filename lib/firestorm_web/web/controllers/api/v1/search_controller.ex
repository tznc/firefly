defmodule FirestormWeb.Web.Api.V1.SearchController do
  @moduledoc """
  `GET /api/v1/search?q=...`: the search page's results as JSON. Takes the
  same parameters (`q` with inline filters, `category`, `tag`, `user`, `in`,
  `order`, `muted=include`, `page`). No token needed; a token searches as
  its user. Rate limited (the `:search` bucket): per user with a token, else
  per client IP.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.{RateLimit, Search}

  def index(conn, params) do
    user = conn.assigns[:current_user]

    case RateLimit.check_search(user, conn.remote_ip) do
      :ok ->
        search = Search.parse(params["q"], Map.take(params, ~w(category tag user in order muted)))
        render(conn, :index, page: Search.run(search, user, params["page"] || 1))

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{"error" => RateLimit.message()})
    end
  end
end
