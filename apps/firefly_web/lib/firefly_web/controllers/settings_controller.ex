defmodule FireflyWeb.SettingsController do
  @moduledoc """
  The site settings as a file (admins only, behind the `:admin` pipeline):
  `/staff/settings/export/json` or `/yaml`, the settings changed from
  their default (`?all=1`: every one), never secrets. See
  `Firefly.SiteSettings.Transfer`.
  """
  use FireflyWeb, :controller

  alias Firefly.SiteSettings.Transfer

  # Sobelow: admins only; JSON or YAML, as a download (content-disposition: attachment).
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  def export(conn, %{"format" => format} = params) when format in ~w(json yaml) do
    opts = [all: params["all"] == "1"]

    {type, body} =
      if format == "json",
        do: {"application/json", Transfer.export(:json, opts)},
        else: {"application/yaml", Transfer.export(:yaml, opts)}

    conn
    |> put_resp_content_type(type)
    |> put_resp_header(
      "content-disposition",
      ~s{attachment; filename="site-settings-#{Date.utc_today()}.#{format}"}
    )
    |> send_resp(200, body)
  end

  def export(conn, _params), do: send_resp(conn, 404, "Pick json or yaml.")
end
