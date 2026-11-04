defmodule FireflyWeb.Api.V1.SearchController do
  @moduledoc """
  `GET /api/v1/search?q=...`: the search page's results as JSON. Takes the
  same parameters (`q` with inline filters, `category`, `tag`, `user`, `in`,
  `order`, `muted=include`, `page`). No key needed; a key searches as
  its user. Rate limited (the `:search` bucket): per user with a key, else
  per client IP.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.RateLimit
  alias Firefly.Discussion.Search

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read")

  def index(conn, params) do
    user = current_user(conn)

    with :ok <- RateLimit.check_search(user, conn.remote_ip) do
      search = Search.parse(params["q"], Map.take(params, ~w(category tag user in order muted)))
      render(conn, :index, page: Search.run(search, user, params["page"] || 1))
    end
  end
end
