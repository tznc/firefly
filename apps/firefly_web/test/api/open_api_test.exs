defmodule FireflyWeb.Api.OpenAPITest do
  use FireflyWeb.ConnCase, async: true

  alias FireflyWeb.Api.V1.OpenAPI

  # Served outside the spec: the document itself, its page and the 404s.
  @undocumented [{:get, "/openapi.json"}, {:get, "/docs"}, {:*, "/*path"}]

  test "documents every /api/v1 route, and only those" do
    routes =
      for %{path: "/api/v1" <> path, verb: verb} <- Phoenix.Router.routes(FireflyWeb.Router),
          {verb, path} not in @undocumented,
          into: MapSet.new(),
          do: {verb, String.replace(path, ~r/:(\w+)/, "{\\1}")}

    documented = MapSet.new(OpenAPI.operations(), fn op -> {elem(op, 0), elem(op, 1)} end)

    assert MapSet.difference(routes, documented) == MapSet.new(), "routes missing from the spec"
    assert MapSet.difference(documented, routes) == MapSet.new(), "spec operations with no route"
  end

  test "is a well-formed OpenAPI 3.1 document", %{conn: conn} do
    spec = conn |> get(~p"/api/v1/openapi.json") |> json_response(200)

    assert spec["openapi"] == "3.1.0"
    ids = for {_path, ops} <- spec["paths"], {_verb, op} <- ops, do: op["operationId"]
    assert length(ids) == length(Enum.uniq(ids))

    # Every reference resolves.
    refs =
      spec |> Jason.encode!() |> then(&Regex.scan(~r{"\$ref":"#/components/(\w+)/(\w+)"}, &1))

    for [_, kind, name] <- refs do
      assert Map.has_key?(spec["components"][kind], name), "unresolved #{kind}/#{name}"
    end

    # The schemas are valid JSON Schema.
    assert %ExJsonSchema.Schema.Root{} =
             ExJsonSchema.Schema.resolve(%{"components" => spec["components"]})
  end

  test "the docs page loads the pinned reference renderer", %{conn: conn} do
    html = conn |> get(~p"/api/v1/docs") |> html_response(200)
    assert html =~ ~s{spec-url="/api/v1/openapi.json"}
    assert html =~ ~s{integrity="sha384-}
  end

  test "unknown endpoints are problem 404s", %{conn: conn} do
    conn = get(conn, "/api/v1/nope")
    assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")

    assert %{"status" => 404, "title" => "Not Found"} =
             json_response(conn, 404) |> assert_schema("Problem")
  end
end
