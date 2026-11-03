defmodule FireflyWeb.Api.V1.PreviewController do
  @moduledoc "`POST /api/v1/preview`: a post body (`post[body]`) rendered as the composer previews it."
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Rendering.Markdown

  plug(:require_scope, "read")

  def create(conn, params) do
    body = get_in(params, ["post", "body"]) || params["body"]
    ok(conn, %{html: Markdown.render(body, current_user(conn))}, 201)
  end
end
