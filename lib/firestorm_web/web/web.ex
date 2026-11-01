defmodule FirestormWeb.Web do
  @moduledoc """
  The entrypoint for defining the web interface: controllers, LiveViews,
  components, channels and so on.

      use FirestormWeb.Web, :controller
      use FirestormWeb.Web, :live_view
      use FirestormWeb.Web, :html

  The definitions below are executed for every controller, LiveView,
  component, etc, so keep them short and focused on imports, uses and aliases.
  Do NOT define functions inside the quoted expressions.
  """

  def static_paths do
    ~w(assets fonts images favicon.ico robots.txt manifest.json browserconfig.xml) ++
      ~w(favicon-16x16.png favicon-32x32.png favicon-96x96.png) ++
      ~w(android-icon-36x36.png android-icon-48x48.png android-icon-72x72.png) ++
      ~w(android-icon-96x96.png android-icon-144x144.png android-icon-192x192.png) ++
      ~w(apple-icon.png apple-icon-precomposed.png apple-icon-57x57.png apple-icon-60x60.png) ++
      ~w(apple-icon-72x72.png apple-icon-76x76.png apple-icon-114x114.png) ++
      ~w(apple-icon-120x120.png apple-icon-144x144.png apple-icon-152x152.png) ++
      ~w(apple-icon-180x180.png ms-icon-70x70.png ms-icon-144x144.png) ++
      ~w(ms-icon-150x150.png ms-icon-310x310.png)
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      use Gettext, backend: FirestormWeb.Web.Gettext
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: FirestormWeb.Web.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      if Application.compile_env(:firestorm_web, :sql_sandbox) do
        on_mount(FirestormWeb.Web.LiveAcceptance)
      end

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: FirestormWeb.Web.Gettext

      import Phoenix.HTML
      import FirestormWeb.Web.CoreComponents
      import FirestormWeb.Web.ForumComponents

      alias Phoenix.LiveView.JS
      alias FirestormWeb.Web.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FirestormWeb.Web.Endpoint,
        router: FirestormWeb.Web.Router,
        statics: FirestormWeb.Web.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
