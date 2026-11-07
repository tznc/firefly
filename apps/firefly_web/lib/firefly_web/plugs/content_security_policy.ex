defmodule FireflyWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  The pages' Content-Security-Policy: scripts only from this site, plus
  inline scripts carrying this response's nonce (`conn.assigns.csp_nonce`,
  fresh for every request). The root layout's own inline script carries
  it, and so do the scripts of a theme an admin allowed to run them (see
  `Firefly.Themes.html/3`); any other inline script or event handler
  attribute doesn't run; the bot challenge's provider, when it's Turnstile
  or hCaptcha, is allowed too (`Firefly.Security.Challenge.script_sources/0`).
  Pages are also kept from being framed elsewhere, and plugins (`object`)
  are off.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()
    sources = Enum.map(Firefly.Security.Challenge.script_sources(), &[" ", &1])

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header(
      "content-security-policy",
      "base-uri 'self'; frame-ancestors 'self'; object-src 'none'; " <>
        IO.iodata_to_binary(["script-src 'self' 'nonce-", nonce, "'" | sources])
    )
  end
end
