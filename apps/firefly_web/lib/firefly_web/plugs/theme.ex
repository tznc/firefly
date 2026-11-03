defmodule FireflyWeb.Plugs.Theme do
  @moduledoc """
  Picks the theme the page uses (see `Firefly.Themes.active/2`): the one
  an admin previews (`preview_theme_id` in their session), the member's
  pick, or the site's default. Assigns `:site_theme` (or nil, the built-in
  look) and `:theme_preview` (whether it's a preview) for the root layout.
  """

  import Plug.Conn

  alias Firefly.Themes

  def init(opts), do: opts

  def call(conn, _opts) do
    preview_id = get_session(conn, :preview_theme_id)
    theme = Themes.active(conn.assigns[:current_user], preview_id)

    conn
    |> assign(:site_theme, theme)
    |> assign(:theme_preview, theme != nil and theme.id == preview_id)
  end
end
