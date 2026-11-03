defmodule FireflyWeb.Api.V1.PreviewControllerTest do
  use FireflyWeb.ConnCase
  alias Firefly.Rendering.Markdown

  test "POST /", %{conn: conn} do
    post = %{
      "body" => "this is **neat**"
    }

    conn = post conn, "/api/v1/preview", post: post
    response = json_response(conn, 201)["data"]
    assert response["html"] == Markdown.render(post["body"])
  end
end
