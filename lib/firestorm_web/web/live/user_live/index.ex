defmodule FirestormWeb.Web.UserLive.Index do
  @moduledoc "The paginated user directory."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Users")}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :users_page, Forums.paginate_users(params["page"]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Users" navigate={~p"/users"} />

      <ul id="users" class="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4">
        <li :for={user <- @users_page.entries} id={"user-#{user.id}"}>
          <.link
            navigate={~p"/users/#{user}"}
            class="card items-center gap-2 border border-base-300 bg-base-100 p-4 transition hover:border-primary"
          >
            <.avatar user={user} size="size-14" />
            <span class="truncate text-sm font-medium">{user.username}</span>
          </.link>
        </li>
      </ul>

      <.pagination page={@users_page} path={~p"/users"} />
    </Layouts.app>
    """
  end
end
