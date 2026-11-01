defmodule FirestormWeb.Admin.Theme do
  @moduledoc """
  Kaffy extension that re-skins the admin to match the forum: the Firefly
  stylesheet (`assets/css/admin.css`), favicon, and the same light/dark
  theme choice as the rest of the site (stored in `localStorage`).
  """

  alias FirestormWeb.Web.Endpoint

  def stylesheets(_conn) do
    [
      {:safe,
       ~s(<link rel="stylesheet" href="#{Endpoint.static_path("/assets/css/admin.css")}" />)},
      {:safe, ~s(<link rel="icon" type="image/svg+xml" href="/images/firefly-icon.svg" />)},
      {:safe, theme_script()}
    ]
  end

  # Applies the forum's theme choice before first paint; see root.html.heex.
  defp theme_script do
    """
    <script>
      (() => {
        const stored = localStorage.getItem("phx:theme");
        const dark = stored ? stored === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
        document.documentElement.setAttribute("data-theme", dark ? "firefly-dark" : "firefly");
      })();
    </script>
    """
  end
end
