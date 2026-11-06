defmodule FireflyWeb.Api.V1.DocsController do
  @moduledoc """
  The API's OpenAPI document (`/api/v1/openapi.json`), its reference page
  (`/api/v1/docs`, Redoc from a pinned CDN build checked by subresource
  integrity), and a problem `404` for any other `/api/v1` path.
  """
  use FireflyWeb, :controller

  alias FireflyWeb.Api.V1.OpenAPI

  @redoc "https://cdn.jsdelivr.net/npm/redoc@2.1.5/bundles/redoc.standalone.js"
  @redoc_integrity "sha384-0GrsyTQc9Oqd8h+b2dbc4XdR2T/DYpy0tLNNstyx+LBMUyiBbcWPbEs9aRmUcaxD"

  def spec(conn, _params), do: json(conn, OpenAPI.spec())

  # Sobelow: a fixed page; the one interpolated value, the site title, is HTML-escaped.
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, _params) do
    title =
      Phoenix.HTML.safe_to_string(
        Phoenix.HTML.html_escape("#{Firefly.SiteSettings.get("title")} API")
      )

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>#{title}</title>
      </head>
      <body>
        <redoc spec-url="#{~p"/api/v1/openapi.json"}"></redoc>
        <noscript>The reference needs JavaScript; the document itself is at <a href="#{~p"/api/v1/openapi.json"}">openapi.json</a>.</noscript>
        <script src="#{@redoc}" integrity="#{@redoc_integrity}" crossorigin="anonymous"></script>
      </body>
    </html>
    """)
  end

  def not_found(conn, _params), do: FireflyWeb.Api.Problem.send(conn, 404, "No such endpoint.")
end
