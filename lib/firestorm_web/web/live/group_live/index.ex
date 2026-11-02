defmodule FirestormWeb.Web.GroupLive.Index do
  @moduledoc "The groups the viewer may see (see `FirestormWeb.Groups`), with their member counts."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Groups

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Groups")
     |> assign(:groups, Groups.list_visible(socket.assigns.current_user))}
  end

  defp mode("open"), do: "Anyone can join"
  defp mode("request"), do: "Ask to join"
  defp mode("invite"), do: "By invitation"
  defp mode("closed"), do: "Closed"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Groups" />
      <ul id="groups" class="list rounded-box border border-base-300 bg-base-100">
        <li :if={@groups == []} class="list-row text-base-content/60">No groups to show.</li>
        <li :for={{group, count} <- @groups} id={"group-#{group.id}"} class="list-row items-center">
          <.icon name="hero-user-group" class="size-6 opacity-60" />
          <div class="list-col-grow min-w-0">
            <.link navigate={~p"/groups/#{group.name}"} class="font-medium hover:text-primary">
              {group.name}
            </.link>
            <p :if={group.description} class="truncate text-sm text-base-content/60">
              {group.description}
            </p>
          </div>
          <span class="badge badge-ghost badge-sm">{mode(group.membership)}</span>
          <span class="text-sm text-base-content/60">
            {count} {if count == 1, do: "member", else: "members"}
          </span>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
