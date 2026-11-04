defmodule FireflyWeb.StaffLive.Groups do
  @moduledoc """
  Groups (roles), admins only: create, rename and delete them, set who
  sees, joins, mentions and messages each, and add or remove members (see
  `Firefly.Groups`). The staff and trust level groups keep their names. Owners and requests are managed on each group's
  page. Categories are restricted to groups on the category's edit page.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Groups
  alias Firefly.Groups.Role

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_groups) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Groups"))
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
         |> put_flash(:info, gettext("Group %{name} created.", name: role.name))
         |> assign(:form, to_form(Groups.change_group()))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp group_event("update_settings", %{"role_id" => role_id, "group" => params}, socket) do
    role = Groups.get_group!(role_id)

    case Groups.update_settings(role, params, socket.assigns.current_user) do
      {:ok, role} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{name}'s settings.", name: role.name))
         |> load()}

      {:error, changeset} ->
        message =
          Enum.map_join(changeset.errors, "; ", fn {field, {text, _}} -> "#{field} #{text}" end)

        {:noreply, put_flash(socket, :error, gettext("Not saved: %{message}", message: message))}
    end
  end

  defp group_event("add_member", %{"role_id" => role_id, "username" => username}, socket) do
    role = Groups.get_group!(role_id)

    case Groups.add_member(role, username, socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Added @%{username} to %{name}.", username: user.username, name: role.name)
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Groups.message(reason))}
    end
  end

  defp group_event("remove_member", %{"role_id" => role_id, "user_id" => user_id}, socket) do
    role = Groups.get_group!(role_id)
    user = Firefly.Accounts.get_user!(user_id)

    case Groups.remove_member(role, user, socket.assigns.current_user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Removed @%{username} from %{name}.", username: user.username, name: role.name)
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Groups.message(reason))}
    end
  end

  defp group_event("rename", %{"role_id" => role_id, "name" => name}, socket) do
    role = Groups.get_group!(role_id)

    case Groups.rename_group(role, name, socket.assigns.current_user) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Renamed %{old} to %{new}.", old: role.name, new: renamed.name)
         )
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        message = Enum.map_join(changeset.errors, "; ", fn {_field, {text, _}} -> text end)

        {:noreply,
         put_flash(socket, :error, gettext("Not renamed: name %{message}", message: message))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Groups.message(reason))}
    end
  end

  defp group_event("delete", %{"role_id" => role_id}, socket) do
    role = Groups.get_group!(role_id)

    case Groups.delete_group(role, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Deleted %{name}.", name: role.name)) |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Groups.message(reason))}
    end
  end

  defp label("public"), do: gettext("Everyone")
  defp label("members"), do: gettext("Its members")
  defp label("staff"), do: gettext("Staff")
  defp label("closed"), do: gettext("Owners and staff add members")
  defp label("open"), do: gettext("Anyone can join")
  defp label("request"), do: gettext("Anyone can ask; owners approve")
  defp label("invite"), do: gettext("Owners invite")
  defp label("nobody"), do: gettext("Staff only")
  defp label("owners"), do: gettext("Owners")
  defp label("everyone"), do: gettext("Everyone")

  defp options(values), do: Enum.map(values, &{label(&1), &1})

  defp fixed?(group), do: Role.staff?(group) or Role.automatic?(group)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Groups")} navigate={~p"/staff/groups"}>
        <:subtitle>
          {gettext("Set what each group may do in each category at Categories. Members of admin and moderator are staff.")}
        </:subtitle>
      </.page_header>

      <.form for={@form} id="group-form" phx-submit="create" class="flex items-end gap-2">
        <.input field={@form[:name]} type="text" label={gettext("New group")} placeholder={gettext("Name")} />
        <.button variant="primary" class="mb-2">{gettext("Create group")}</.button>
      </.form>

      <p :if={@groups == []} class="text-base-content/70">{gettext("No groups yet.")}</p>

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
          <div class="flex flex-wrap items-center gap-2">
            <.link navigate={~p"/groups/#{group.name}"} class="link text-sm">{gettext("Group page")}</.link>
            <form :if={!fixed?(group)} id={"rename-#{group.id}"} phx-submit="rename" class="flex items-center gap-1">
              <input type="hidden" name="role_id" value={group.id} />
              <input
                type="text"
                name="name"
                value={group.name}
                class="input input-xs w-32"
                aria-label={gettext("New name for %{name}", name: group.name)}
              />
              <button class="btn btn-xs">{gettext("Rename")}</button>
            </form>
            <button
              :if={!fixed?(group)}
              phx-click="delete"
              phx-value-role_id={group.id}
              data-confirm={gettext("Delete %{name}? Its members leave it.", name: group.name)}
              class="btn btn-xs btn-ghost"
            >
              {gettext("Delete")}
            </button>
          </div>
          <.form
            for={%{}}
            as={:group}
            id={"group-settings-#{group.id}"}
            phx-submit="update_settings"
            class="grid gap-2 sm:grid-cols-4"
          >
            <input type="hidden" name="role_id" value={group.id} />
            <.input name="group[visibility]" type="select" label={gettext("Who sees it")} value={group.visibility} options={options(Role.visibilities())} />
            <.input name="group[membership]" type="select" label={gettext("Joining")} value={group.membership} options={options(Role.memberships())} />
            <.input name="group[mentionable]" type="select" label={gettext("Who can @mention it")} value={group.mentionable} options={options(Role.levels())} />
            <.input name="group[messageable]" type="select" label={gettext("Who can message it")} value={group.messageable} options={options(Role.levels())} />
            <div class="sm:col-span-4">
              <button class="btn btn-sm">{gettext("Save settings")}</button>
            </div>
          </.form>
          <p :if={group.categories != []} class="flex flex-wrap items-center gap-1 text-sm">
            <.icon name="hero-lock-closed" class="size-4 opacity-60" /> {gettext("Can read")}
            <.category_badge :for={category <- group.categories} category={category} />
          </p>
          <ul class="flex flex-wrap gap-2">
            <li :for={user <- group.users} class="badge badge-outline gap-1" id={"group-#{group.id}-user-#{user.id}"}>
              <.link navigate={~p"/users/#{user}"}>@{user.username}</.link>
              <button
                phx-click="remove_member"
                phx-value-role_id={group.id}
                phx-value-user_id={user.id}
                aria-label={gettext("Remove %{username}", username: user.username)}
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
              placeholder={gettext("username")}
              aria-label={gettext("Add a member to %{name}", name: group.name)}
              class="input input-sm"
            />
            <button class="btn btn-sm">{gettext("Add member")}</button>
          </form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
