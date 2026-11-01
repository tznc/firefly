defmodule FirestormWeb.Web.Api.V1.SearchController do
  @moduledoc """
  `GET /api/v1/search?q=...`: the search page's results as JSON. Takes the
  same parameters (`q` with inline filters, `category`, `tag`, `user`, `in`,
  `order`, `page`). No token needed; a token searches as its user.
  """
  use FirestormWeb.Web, :controller

  alias FirestormWeb.Search

  def index(conn, params) do
    search = Search.parse(params["q"], Map.take(params, ~w(category tag user in order)))
    page = Search.run(search, conn.assigns[:current_user], params["page"] || 1)
    render(conn, :index, page: page)
  end
end
