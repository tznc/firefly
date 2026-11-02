defmodule FireflyWeb do
  @moduledoc """
  The entrypoint for defining the web interface: controllers, LiveViews,
  components, channels and so on.

      use FireflyWeb, :controller
      use FireflyWeb, :live_view
      use FireflyWeb, :html

  The definitions below are executed for every controller, LiveView,
  component, etc, so keep them short and focused on imports, uses and aliases.
  Do NOT define functions inside the quoted expressions.
  """

  def static_paths,
    do: ~w(assets fonts images vendor favicon.ico robots.txt manifest.json service-worker.js)

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
      use Gettext, backend: FireflyWeb.Gettext

      import FireflyWeb.Authorization, only: [can?: 3]
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: FireflyWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      if Application.compile_env(:firefly_web, :sql_sandbox) do
        on_mount(FireflyWeb.LiveAcceptance)
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
      use Gettext, backend: FireflyWeb.Gettext

      import Phoenix.HTML
      import FireflyWeb.CoreComponents
      import FireflyWeb.ForumComponents
      import FireflyWeb.Authorization

      alias Phoenix.LiveView.JS
      alias FireflyWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: FireflyWeb.Endpoint,
        router: FireflyWeb.Router,
        statics: FireflyWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
