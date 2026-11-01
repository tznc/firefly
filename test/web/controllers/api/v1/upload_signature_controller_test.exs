defmodule FirestormWeb.Web.Api.V1.UploadSignatureControllerTest do
  use FirestormWeb.Web.ConnCase

  @upload %{"filename" => "image.jpg", "mimetype" => "image/jpeg"}

  test "requires an API token", %{conn: conn} do
    conn = post(conn, "/api/v1/upload_signature", upload: @upload)
    assert json_response(conn, 401)["error"] == "Authentication required"
  end

  test "returns a presigned POST for authenticated users", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{user.api_token}")
      |> post("/api/v1/upload_signature", upload: @upload)

    data = json_response(conn, 201)["data"]
    assert data["action"] =~ "amazonaws.com"
    assert data["fields"]["x-amz-signature"]
    assert data["fields"]["Content-Type"] == "image/jpeg"
  end

  test "refuses unsupported file types", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{user.api_token}")
      |> post("/api/v1/upload_signature", upload: %{@upload | "mimetype" => "text/html"})

    assert json_response(conn, 422)["error"] == "unsupported file type"
  end
end
