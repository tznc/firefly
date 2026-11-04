defmodule FireflyWeb.Admin.Theme do
  @moduledoc """
  Kaffy extension that fits the database admin into the site: the Firefly
  skin (`assets/css/admin.css`, which reads the daisyUI color tokens),
  the colors of the site's active theme (`Firefly.Themes.color_css/1`;
  its CSS and HTML are written for the forum's pages, not these), the
  favicon, the same light/dark choice as the rest of the site (stored in
  `localStorage`), and a banner saying what this admin is for.
  """

  use Gettext, backend: FireflyWeb.Gettext

  alias Firefly.Themes
  alias FireflyWeb.Endpoint

  def stylesheets(conn) do
    theme =
      Themes.active(conn.assigns[:current_user], Plug.Conn.get_session(conn, :preview_theme_id))

    [
      {:safe,
       ~s(<link rel="stylesheet" href="#{Endpoint.static_path("/assets/css/admin.css")}" />)},
      {:safe, ~s(<link rel="icon" type="image/svg+xml" href="/images/firefly-icon.svg" />)},
      {:safe, if(theme, do: "<style>#{Themes.color_css(theme)}</style>", else: "")},
      {:safe, theme_script()}
    ]
  end

  def javascripts(_conn) do
    # Translated with the path as a placeholder, escaped, then linked.
    sentence =
      gettext(
        "Raw database records. The staff admin at %{path} is the primary way to run the site; edits here bypass its validation and side effects.",
        path: "/staff"
      )

    text =
      sentence
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
      |> String.replace("/staff", ~s(<a href="/staff">/staff</a>), global: false)

    [
      {:safe,
       """
       <div id="database-admin-banner" class="ff-db-banner" role="note">#{text}</div>
       <script>
         (() => {
           const wrapper = document.querySelector(".content-wrapper");
           if (wrapper) wrapper.prepend(document.getElementById("database-admin-banner"));
           // Kaffy's icon-only buttons and row checkboxes have no names.
           const name = (selector, label) =>
             document.querySelectorAll(selector).forEach((el) => el.setAttribute("aria-label", label));
           name(".navbar-toggler", #{Jason.encode!(gettext("Toggle the menu"), escape: :html_safe)});
           name("#kaffy-select-all", #{Jason.encode!(gettext("Select all"), escape: :html_safe)});
           name("input[id^=kaffy-select-]:not(#kaffy-select-all)", #{Jason.encode!(gettext("Select"), escape: :html_safe)});
         })();
       </script>
       """}
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
