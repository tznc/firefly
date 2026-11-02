defmodule FirestormWeb.Web.PluginLive.Page do
  @moduledoc """
  A plugin's pages at `/plugins/:id/*path`, from its `render_page` hook:
  sanitized HTML in the site's layout, or the plugin's asset as an app in a
  sandboxed frame (see `FirestormWeb.Plugins.UI`).
  """
  use FirestormWeb.Web, :live_view

  import FirestormWeb.Web.PluginComponents

  alias FirestormWeb.Plugins
  alias FirestormWeb.Plugins.UI

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    path = "/" <> Enum.join(params["path"] || [], "/")
    user = socket.assigns.current_user

    input = %{
      "path" => path,
      "params" => Map.drop(params, ["id", "path"]),
      "user" => UI.public_user(user)
    }

    case UI.render(id, "render_page", input) do
      {:ok, view} ->
        {:ok,
         socket
         |> assign(:page_title, view.title)
         |> assign(plugin: Plugins.get_active(id), view: view, path: path)}

      {:error, _reason} ->
        {:ok, socket |> put_flash(:error, "Page not found.") |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={@view.title} />
      <.plugin_view
        id={"plugin-page-#{@plugin.id}"}
        plugin={@plugin}
        view={@view}
        context={%{path: @path}}
        user={@current_user}
      />
    </Layouts.app>
    """
  end
end
