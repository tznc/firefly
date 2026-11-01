defmodule FirestormWeb.Web.StaffLive.Groups do
  @moduledoc """
  Groups (roles), admins only: create them and add or remove members (see
  `FirestormWeb.Groups`). Categories are restricted to groups on the
  category's edit page.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Groups

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_groups) do
      {:ok,
       socket
       |> assign(:page_title, "Groups")
       |> assign(:form, to_form(Groups.change_group()))
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket), do: assign(socket, :groups, Groups.list_groups())

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_groups),
      do: group_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp group_event("create", %{"role" => params}, socket) do
    case Groups.create_group(params, socket.assigns.current_user) do
      {:ok, role} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group #{role.name} created.")
         |> assign(:form, to_form(Groups.change_group()))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp group_event("add_member", %{"role_id" => role_id, "username" => username}, socket) do
    role = Groups.get_group!(role_id)

    case Groups.add_member(role, username, socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket |> put_flash(:info, "Added @#{user.username} to #{role.name}.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Groups.message(reason))}
    end
  end

  defp group_event("remove_member", %{"role_id" => role_id, "user_id" => user_id}, socket) do
    role = Groups.get_group!(role_id)
    user = FirestormWeb.Forums.get_user!(user_id)

    case Groups.remove_member(role, user, socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket |> put_flash(:info, "Removed @#{user.username} from #{role.name}.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Groups.message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Groups" navigate={~p"/staff/groups"}>
        <:subtitle>
          Restrict a category to groups on its edit page. Members of "admin" are staff and see everything.
        </:subtitle>
      </.page_header>

      <.form for={@form} id="group-form" phx-submit="create" class="flex items-end gap-2">
        <.input field={@form[:name]} type="text" label="New group" placeholder="Name" />
        <.button variant="primary" class="mb-2">Create group</.button>
      </.form>

      <p :if={@groups == []} class="text-base-content/70">No groups yet.</p>

      <section
        :for={group <- @groups}
        id={"group-#{group.id}"}
        class="card border border-base-300 bg-base-100"
      >
        <div class="card-body gap-3">
          <h2 class="card-title">
            {group.name}
            <span class="badge badge-ghost badge-sm">{length(group.users)}</span>
          </h2>
          <p :if={group.categories != []} class="flex flex-wrap items-center gap-1 text-sm">
            <.icon name="hero-lock-closed" class="size-4 opacity-60" /> Can read
            <.category_badge :for={category <- group.categories} category={category} />
          </p>
          <ul class="flex flex-wrap gap-2">
            <li :for={user <- group.users} class="badge badge-outline gap-1" id={"group-#{group.id}-user-#{user.id}"}>
              <.link navigate={~p"/users/#{user}"}>@{user.username}</.link>
              <button
                phx-click="remove_member"
                phx-value-role_id={group.id}
                phx-value-user_id={user.id}
                aria-label={"Remove #{user.username}"}
                class="cursor-pointer"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </li>
          </ul>
          <form
            id={"add-member-#{group.id}"}
            phx-submit="add_member"
            class="flex items-center gap-2"
          >
            <input type="hidden" name="role_id" value={group.id} />
            <input
              type="text"
              name="username"
              placeholder="username"
              aria-label={"Add a member to #{group.name}"}
              class="input input-sm"
            />
            <button class="btn btn-sm">Add member</button>
          </form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
