defmodule FirestormWeb.Web.ThreadLive.ListView do
  @moduledoc """
  Shared implementation of the thread list pages (latest, new, unread,
  watching, participating). Each page supplies a title, a path and a `load/1`
  function; the list reloads whenever a thread is created, updated, deleted or
  gets a new post. Pass `tabs: true` to show the Latest/New/Unread/Top tabs,
  and `intro: true` to show the site's description (the home page).
  """
  use FirestormWeb.Web, :html

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use FirestormWeb.Web, :live_view

      alias FirestormWeb.Forums

      @list_opts opts

      @impl true
      def mount(_params, _session, socket) do
        if connected?(socket), do: Forums.subscribe("forums:threads")

        {:ok,
         socket
         |> assign(:page_title, @list_opts[:title])
         |> assign(:list_opts, @list_opts)
         |> assign(:threads, load(socket.assigns.current_user))}
      end

      @impl true
      def handle_info({event, _thread}, socket)
          when event in [:thread_created, :thread_updated, :thread_deleted, :thread_activity] do
        {:noreply, assign(socket, :threads, load(socket.assigns.current_user))}
      end

      @impl true
      def render(assigns), do: FirestormWeb.Web.ThreadLive.ListView.list_page(assigns)
    end
  end

  @doc false
  def list_page(assigns) do
    description = if assigns.list_opts[:intro], do: FirestormWeb.SiteSettings.get("description")
    assigns = assign(assigns, :description, description)

    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <p :if={@description not in [nil, ""]} id="site-description" class="text-base-content/80">
        {@description}
      </p>
      <.page_header :if={@list_opts[:title]} title={@list_opts[:title]} navigate={@list_opts[:path]} />
      <.list_tabs :if={@list_opts[:tabs]} current_path={@list_opts[:path]} current_user={@current_user} />
      <.thread_list threads={@threads} empty={@list_opts[:empty]} />
    </Layouts.app>
    """
  end
end
