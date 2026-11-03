defmodule FireflyWeb.ThemeController do
  @moduledoc """
  Themes outside the LiveViews (see `Firefly.Themes`): a theme's compiled
  stylesheet, public and cached for a year (its URL names its version);
  and, for admins (behind the `:admin` pipeline), previewing a theme in
  their own session and downloading a theme's JSON bundle.
  """
  use FireflyWeb, :controller

  alias Firefly.Themes

  @doc "The compiled stylesheet of the theme `id` (any version asked gets the current one)."
  def css(conn, %{"id" => id, "version" => version}) do
    with {id, ""} <- Integer.parse(id),
         {:ok, current, css} <- Themes.compiled_css(id) do
      # An old version's URL still works, but isn't kept: the page asking
      # for it is about to ask for the new one.
      cache =
        if version == to_string(current),
          do: "public, max-age=31536000, immutable",
          else: "no-cache"

      conn
      |> put_resp_content_type("text/css")
      |> put_resp_header("cache-control", cache)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, css)
    else
      _missing -> send_resp(conn, 404, "")
    end
  end

  @doc "Shows the site with the theme `id`, for this admin's session only."
  def preview(conn, %{"id" => id}) do
    theme = Themes.get_theme!(id)

    if theme.component do
      conn
      |> put_flash(:error, Themes.message(:component))
      |> redirect(to: ~p"/staff/themes/#{theme.id}")
    else
      conn
      |> put_session(:preview_theme_id, theme.id)
      |> put_flash(:info, gettext("Previewing %{name}: only you see it.", name: theme.name))
      |> redirect(to: ~p"/")
    end
  end

  @doc "Stops previewing."
  def stop_preview(conn, _params) do
    id = get_session(conn, :preview_theme_id)

    conn
    |> delete_session(:preview_theme_id)
    |> put_flash(:info, gettext("Stopped previewing."))
    |> redirect(to: if(id, do: ~p"/staff/themes/#{id}", else: ~p"/staff/themes"))
  end

  @doc "The theme's JSON bundle, to import elsewhere."
  def export(conn, %{"id" => id}) do
    theme = Themes.get_theme!(id)
    filename = String.replace(String.downcase(theme.name), ~r/[^a-z0-9]+/, "-")

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s{attachment; filename="#{filename}.json"})
    |> send_resp(200, Themes.export(theme))
  end
end
