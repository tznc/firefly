defmodule FireflyWeb.Api.V1.PreviewController do
  use FireflyWeb, :controller
  alias Firefly.Markdown

  def create(conn, %{"post" => post_params}) do
    conn
    |> put_status(201)
    |> render(:show, html: Markdown.render(post_params["body"], conn.assigns[:current_user]))
  end
end
