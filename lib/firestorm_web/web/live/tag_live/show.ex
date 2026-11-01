defmodule FirestormWeb.Web.TagLive.Show do
  @moduledoc """
  A tag's threads, most recently active first; updates live. A synonym's
  page redirects to its canonical tag's (see `FirestormWeb.Tags`).
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Subscriptions, Tag}

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Forums.get_tag!(name) do
      %{synonym_of: %Tag{name: canonical}} ->
        {:ok, push_navigate(socket, to: ~p"/tags/#{canonical}")}

      tag ->
        mount_tag(tag, socket)
    end
  end

  defp mount_tag(tag, socket) do
    if connected?(socket), do: Forums.subscribe("forums:threads")

    {:ok,
     socket
     |> assign(:page_title, "##{tag.name}")
     |> assign(:tag, tag)
     |> assign(:level, Subscriptions.tag_level(socket.assigns.current_user, tag))
     |> load_threads()}
  end

  @impl true
  def handle_info({_event, _thread}, socket), do: {:noreply, load_threads(socket)}

  @impl true
  def handle_event("set_level", %{"level" => level}, %{assigns: %{current_user: user}} = socket)
      when not is_nil(user) do
    if level in Subscriptions.levels() do
      {:ok, _} = Subscriptions.set_tag_level(user, socket.assigns.tag, level)
      {:noreply, socket |> assign(:level, level) |> load_threads()}
    else
      {:noreply, socket}
    end
  end

  defp load_threads(socket) do
    assign(socket, :threads, Forums.tag_threads(socket.assigns.tag, socket.assigns.current_user))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={"##{@tag.name}"} navigate={~p"/tags/#{@tag.name}"}>
        <:subtitle><.link navigate={~p"/tags"} class="link">All tags</.link></:subtitle>
        <:actions>
          <.level_picker :if={@current_user} id="tag-level" level={@level} />
        </:actions>
      </.page_header>

      <.thread_list threads={@threads} empty="No threads with this tag." />
    </Layouts.app>
    """
  end
end
