defmodule FireflyWeb.StaffLive.Categories do
  @moduledoc """
  The categories admin (admins only): every category in order with its
  subcategories, moved up and down among its siblings, created, edited
  (at `FireflyWeb.CategoryLive.Form`) and deleted; for each, which
  groups it's restricted to and what each may do there (start threads and
  reply, reply, or only read; see `Firefly.Discussion.Policy`), and the
  notification level new members start at, which can also be given to
  existing members who haven't chosen one. Every change is staff-logged.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Discussion, Groups}
  alias Firefly.Notifications.Subscriptions

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_category) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Categories"))
       |> assign(:groups, Groups.list_groups())
       |> assign(:open, nil)
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket) do
    tree = Discussion.list_category_tree(socket.assigns.current_user)

    permissions =
      for category <- Enum.flat_map(tree, &[&1 | &1.children]), into: %{} do
        {category.id,
         Map.new(Discussion.category_permissions(category), fn {r, p} -> {r.id, p} end)}
      end

    socket
    |> assign(:tree, tree)
    |> assign(:permissions, permissions)
  end

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_category),
      do: category_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp category_event("move", %{"id" => id, "direction" => direction}, socket)
       when direction in ["up", "down"] do
    category = Discussion.get_category!(id)

    {:ok, _} =
      Discussion.move_category(
        category,
        String.to_existing_atom(direction),
        socket.assigns.current_user
      )

    {:noreply, load(socket)}
  end

  defp category_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, :open, if(socket.assigns.open == id, do: nil, else: id))}
  end

  defp category_event("save_permissions", %{"category_id" => id} = params, socket) do
    category = Discussion.get_category!(id)

    {:ok, _} =
      Discussion.set_category_permissions(
        category,
        params["permissions"] || %{},
        socket.assigns.current_user
      )

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Saved who can see and post in %{title}.", title: category.title)
     )
     |> load()}
  end

  defp category_event("save_defaults", %{"category_id" => id, "level" => level}, socket) do
    category = Discussion.get_category!(id)

    case Discussion.update_category(
           category,
           %{"default_notification_level" => level},
           socket.assigns.current_user
         ) do
      {:ok, category} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved %{title}'s default.", title: category.title))
         |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Pick a notification level."))}
    end
  end

  defp category_event("apply_default", %{"id" => id}, socket) do
    category = Discussion.get_category!(id)
    {:ok, count} = Discussion.apply_category_default(category, socket.assigns.current_user)

    {:noreply,
     put_flash(
       socket,
       :info,
       ngettext("1 member got the default.", "%{count} members got the default.", count)
     )}
  end

  defp category_event("delete", %{"id" => id}, socket) do
    category = Discussion.get_category!(id)

    case Discussion.delete_category(category, socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Category deleted.")) |> load()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("It couldn't be deleted: move its threads and subcategories out first.")
         )}
    end
  end

  defp permission_label("full"), do: gettext("Start threads and reply")
  defp permission_label("create_post"), do: gettext("Reply")
  defp permission_label("readonly"), do: gettext("Read only")

  defp level_label("watching"), do: gettext("Watching")
  defp level_label("tracking"), do: gettext("Tracking")
  defp level_label("normal"), do: gettext("Normal")
  defp level_label("muted"), do: gettext("Muted")

  attr :category, :any, required: true
  attr :first, :boolean, required: true
  attr :last, :boolean, required: true
  attr :open, :any, required: true
  attr :groups, :list, required: true
  attr :permissions, :map, required: true
  attr :sub, :boolean, default: false

  defp category_row(assigns) do
    ~H"""
    <li id={"category-#{@category.id}"} class={["rounded-box border border-base-300 bg-base-100 p-3", @sub && "ml-6"]}>
      <div class="flex flex-wrap items-center gap-2">
        <div class="join">
          <button
            phx-click="move"
            phx-value-id={@category.id}
            phx-value-direction="up"
            disabled={@first}
            class="btn btn-xs join-item"
            aria-label={gettext("Move %{title} up", title: @category.title)}
          >
            <.icon name="hero-chevron-up" class="size-4" />
          </button>
          <button
            phx-click="move"
            phx-value-id={@category.id}
            phx-value-direction="down"
            disabled={@last}
            class="btn btn-xs join-item"
            aria-label={gettext("Move %{title} down", title: @category.title)}
          >
            <.icon name="hero-chevron-down" class="size-4" />
          </button>
        </div>
        <.category_badge category={@category} />
        <span :if={@permissions[@category.id] != %{}} class="badge badge-sm badge-ghost">
          <.icon name="hero-lock-closed" class="size-3" /> {gettext("restricted")}
        </span>
        <span :if={@category.default_notification_level} class="badge badge-sm badge-ghost">
          {gettext("default: %{level}", level: level_label(@category.default_notification_level))}
        </span>
        <span class="flex-1"></span>
        <button
          phx-click="toggle"
          phx-value-id={@category.id}
          class="btn btn-xs"
          aria-expanded={to_string(@open == @category.id)}
        >
          {gettext("Permissions and defaults")}
        </button>
        <.link navigate={~p"/categories/#{@category.id}/edit"} class="btn btn-xs">{gettext("Edit")}</.link>
        <button
          phx-click="delete"
          phx-value-id={@category.id}
          data-confirm={gettext("Delete %{title}?", title: @category.title)}
          class="btn btn-xs btn-ghost"
        >
          {gettext("Delete")}
        </button>
      </div>
      <div :if={@open == @category.id} id={"category-settings-#{@category.id}"} class="mt-3 grid gap-4 md:grid-cols-2">
        <form id={"permissions-#{@category.id}"} phx-submit="save_permissions" class="space-y-2">
          <input type="hidden" name="category_id" value={@category.id} />
          <h3 class="font-semibold">{gettext("Who can see and post")}</h3>
          <p class="text-xs text-base-content/70">
            {gettext("No groups: everyone can see it and post. Otherwise only these groups (and staff) can see it, each as allowed.")}
          </p>
          <div :for={group <- @groups} class="flex items-center justify-between gap-2">
            <label for={"permission-#{@category.id}-#{group.id}"} class="text-sm">{group.name}</label>
            <select
              id={"permission-#{@category.id}-#{group.id}"}
              name={"permissions[#{group.id}]"}
              class="select select-sm w-48"
            >
              <option value="">{gettext("No access")}</option>
              <option
                :for={level <- Discussion.category_permission_levels()}
                value={level}
                selected={@permissions[@category.id][group.id] == level}
              >
                {permission_label(level)}
              </option>
            </select>
          </div>
          <button class="btn btn-sm">{gettext("Save permissions")}</button>
        </form>
        <div class="space-y-2">
          <form id={"defaults-#{@category.id}"} phx-submit="save_defaults" class="space-y-2">
            <input type="hidden" name="category_id" value={@category.id} />
            <h3 class="font-semibold">{gettext("Defaults for members")}</h3>
            <label for={"default-level-#{@category.id}"} class="text-sm">
              {gettext("New members' notification level")}
            </label>
            <select id={"default-level-#{@category.id}"} name="level" class="select select-sm w-full">
              <option value="">{gettext("None (they choose)")}</option>
              <option
                :for={level <- Subscriptions.levels()}
                value={level}
                selected={@category.default_notification_level == level}
              >
                {level_label(level)}
              </option>
            </select>
            <button class="btn btn-sm">{gettext("Save default")}</button>
          </form>
          <button
            :if={@category.default_notification_level}
            phx-click="apply_default"
            phx-value-id={@category.id}
            data-confirm={gettext("Give this level to every member who hasn't chosen one for this category?")}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Apply to existing members")}
          </button>
        </div>
      </div>
    </li>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Categories")} navigate={~p"/staff/categories"}>
        <:subtitle>{gettext("Order categories, and set who can see and post in each.")}</:subtitle>
        <:actions>
          <.link navigate={~p"/categories/new"} class="btn btn-primary btn-sm">{gettext("New category")}</.link>
        </:actions>
      </.page_header>

      <p :if={@tree == []} class="text-base-content/70">{gettext("No categories yet.")}</p>

      <ol id="categories" class="space-y-2">
        <%= for {category, index} <- Enum.with_index(@tree) do %>
          <.category_row
            category={category}
            first={index == 0}
            last={index == length(@tree) - 1}
            open={@open}
            groups={@groups}
            permissions={@permissions}
          />
          <.category_row
            :for={{child, child_index} <- Enum.with_index(category.children)}
            category={child}
            first={child_index == 0}
            last={child_index == length(category.children) - 1}
            open={@open}
            groups={@groups}
            permissions={@permissions}
            sub
          />
        <% end %>
      </ol>
    </Layouts.app>
    """
  end
end
