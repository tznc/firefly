defmodule FireflyWeb.Api.V1.PostControllerTest do
  use FireflyWeb.ConnCase

  alias Firefly.{Accounts, Discussion}
  alias Firefly.Rendering.Markdown

  test "POST /", %{conn: conn} do
    {:ok, elixir} = Discussion.create_category(%{title: "Elixir"})

    {:ok, bob} =
      Accounts.register_user(%{
        username: "bob",
        email: "bob@example.com",
        password: "tangerine-otter-galaxy"
      })

    {:ok, bob} = Accounts.confirm_user(bob)

    {:ok, otp_is_cool} =
      Discussion.create_thread(elixir, bob, %{title: "OTP is cool", body: "Don't you think?"})

    post = %{
      "body" => "this is **neat**"
    }

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_token(bob)}")
      |> post("/api/v1/posts", post: post, thread_id: otp_is_cool.id)

    response = json_response(conn, 201)["data"]
    assert response["body_html"] == Markdown.render(post["body"])
  end

  test "requires an API token", %{conn: conn} do
    conn = post(conn, "/api/v1/posts", post: %{"body" => "hi"}, thread_id: 1)
    assert json_response(conn, 401)["detail"] =~ "API key is required"
  end

  test "returns errors for an invalid post and 404 for a missing thread", %{conn: conn} do
    user = user_fixture()
    thread = thread_fixture(category_fixture(), user)
    conn = put_req_header(conn, "authorization", "Bearer #{api_token(user)}")

    assert %{"errors" => %{"body" => ["can't be blank"]}} =
             conn
             |> post("/api/v1/posts", post: %{"body" => ""}, thread_id: thread.id)
             |> json_response(422)

    assert conn
           |> post("/api/v1/posts", post: %{"body" => "x"}, thread_id: 0)
           |> json_response(404)
  end
end
