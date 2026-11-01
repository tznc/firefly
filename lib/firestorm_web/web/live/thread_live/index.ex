defmodule FirestormWeb.Web.ThreadLive.Index do
  @moduledoc "A plain listing of a category's threads, with edit and delete links."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(%{"category_id" => category_id}, _session, socket) do
    category = Forums.get_category!(category_id)
    if connected?(socket), do: Forums.subscribe("forums:category:#{category.id}")

    {:ok,
     socket
     |> assign(:page_title, "Threads - #{category.title}")
     |> assign(:category, category)
     |> assign(:threads, Forums.list_threads(category))}
  end

  @impl true
  def handle_info({_event, _thread}, socket) do
    {:noreply, assign(socket, :threads, Forums.list_threads(socket.assigns.category))}
  end

  @impl true
  def handle_event("delete", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "You must be logged in to access this page.")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    thread = Forums.get_thread!(socket.assigns.category, id)
    {:ok, _} = Forums.delete_thread(thread)

    {:noreply,
     socket
     |> put_flash(:info, "Thread deleted successfully.")
     |> assign(:threads, Forums.list_threads(socket.assigns.category))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Listing Threads">
        <:subtitle>
          in <.link navigate={~p"/categories/#{@category}"} class="link">{@category.title}</.link>
        </:subtitle>
        <:actions>
          <.link navigate={~p"/categories/#{@category}/threads/new"} class="btn btn-primary btn-sm">
            New Thread
          </.link>
        </:actions>
      </.page_header>

      <.table id="threads" rows={@threads} row_id={&"thread-#{&1.id}"}>
        <:col :let={thread} label="Title">{thread.title}</:col>
        <:action :let={thread}>
          <.link navigate={~p"/categories/#{@category}/threads/#{thread}"}>Show</.link>
        </:action>
        <:action :let={thread}>
          <.link navigate={~p"/categories/#{@category}/threads/#{thread}/edit"}>Edit</.link>
        </:action>
        <:action :let={thread}>
          <.link phx-click="delete" phx-value-id={thread.id} data-confirm="Are you sure?">
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
