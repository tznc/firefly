defmodule FirestormWeb.Web do
  @moduledoc """
  A module that keeps using definitions for controllers,
  views and so on.

  This can be used in your application as:

      use FirestormWeb.Web, :controller
      use FirestormWeb.Web, :view

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below.
  """

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [html: "View", json: "View"],
        layouts: [html: {FirestormWeb.Web.LayoutView, :app}]

      use Gettext, backend: FirestormWeb.Web.Gettext

      import Plug.Conn
      import FirestormWeb.Web.Router.Helpers
      import FirestormWeb.Web.Session
      import FirestormWeb.Web.Policy
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/firestorm_web/web/templates",
        namespace: FirestormWeb.Web

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [
          get_csrf_token: 0,
          view_module: 1,
          action_name: 1,
          current_path: 1
        ]

      # Use all HTML functionality (forms, tags, etc)
      import Phoenix.HTML
      import Phoenix.HTML.Form
      use PhoenixHTMLHelpers
      use Gettext, backend: FirestormWeb.Web.Gettext

      import FirestormWeb.Web.Router.Helpers
      import FirestormWeb.Web.ErrorHelpers
      import FirestormWeb.Web.Session
      import FirestormWeb.Web.ViewHelpers
      import FirestormWeb.Web.TagHelpers
      import FirestormWeb.Web.OembedHelpers

      alias FirestormWeb.Web.{
        CategoryView
      }
    end
  end

  def router do
    quote do
      use Phoenix.Router, helpers: true
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      use Gettext, backend: FirestormWeb.Web.Gettext
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
