defmodule FireflyWeb.StaffLive.Categories do
  @moduledoc """
  The categories admin (admins only): every category in order with its
  subcategories, reordered by drag and drop or from the keyboard (the
  `Sortable` hook: Space picks a row up, arrows move it, Space drops it,
  Escape cancels), within a parent or into another one, created, edited
  (at `FireflyWeb.CategoryLive.Form`) and deleted; for each, which
  groups it's restricted to and what each may do there (start threads and
  reply, reply, or only read; see `Firefly.Discussion.Policy`), and the
  notification level new members start at, which can also be given to
  existing members who haven't chosen one. Every change is staff-logged.

  The hook moves the row at once and reverts it if the server says no
  (`place` replies `%{ok: false}`). Other staff with the page open see
  changes live, through the `"forums:categories"` broadcasts.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Accounts, Discussion, Groups}
  alias Firefly.Notifications.Subscriptions

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_category) do
      if connected?(socket), do: Discussion.subscribe("forums:categories")

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
    # Checked against the account as it is now, so an admin demoted while
    # the page is open can't keep changing things from it.
    user = Accounts.get_user!(socket.assigns.current_user.id)

    if can?(user, :manage_category),
      do: category_event(event, params, socket),
      else: denied(event, socket)
  end

  @impl true
  def handle_info({event, _category}, socket)
      when event in [:category_created, :category_updated, :category_deleted],
      do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp denied(event, socket) do
    socket = put_flash(socket, :error, denied_message(socket.assigns.current_user))
    if event == "place", do: {:reply, %{ok: false}, socket}, else: {:noreply, socket}
  end

  # A drop: `id` goes to `index` under `parent_id` (nil for top level).
  defp category_event("place", %{"id" => id, "parent_id" => parent_id, "index" => index}, socket)
       when is_integer(id) and (is_integer(parent_id) or is_nil(parent_id)) and is_integer(index) do
    with %Discussion.Category{} = category <- Discussion.get_category(id),
         {:ok, _} <-
           Discussion.place_category(category, parent_id, index, socket.assigns.current_user) do
      {:reply, %{ok: true}, load(socket)}
    else
      _ ->
        {:reply, %{ok: false},
         socket
         |> put_flash(:error, gettext("That category can't go there."))
         |> load()}
    end
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

  # The live region's messages go to the hook with their placeholders
  # kept, for it to fill in.
  defp slots, do: Map.new(~w(item parent position count)a, &{&1, "%{#{&1}}"})

  defp permission_label("full"), do: gettext("Start threads and reply")
  defp permission_label("create_post"), do: gettext("Reply")
  defp permission_label("readonly"), do: gettext("Read only")

  defp level_label("watching"), do: gettext("Watching")
  defp level_label("tracking"), do: gettext("Tracking")
  defp level_label("normal"), do: gettext("Normal")
  defp level_label("muted"), do: gettext("Muted")

  attr :category, :any, required: true
  attr :open, :any, required: true
  attr :groups, :list, required: true
  attr :permissions, :map, required: true
  attr :sub, :boolean, default: false

  defp category_row(assigns) do
    ~H"""
    <li
      id={"category-#{@category.id}"}
      data-sortable-item
      data-id={@category.id}
      data-label={@category.title}
      data-has-children={to_string(!@sub and @category.children != [])}
    >
      <div data-sortable-row class="rounded-box border border-base-300 bg-base-100 p-3">
      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          draggable="true"
          data-sortable-handle
          class="btn btn-xs btn-ghost cursor-grab"
          aria-label={gettext("Move %{title}", title: @category.title)}
          aria-describedby="category-order-help"
        >
          <.icon name="hero-arrows-up-down" class="size-4" />
        </button>
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
      </div>
      <ol
        :if={!@sub}
        id={"subcategories-#{@category.id}"}
        data-sortable-list
        data-parent={@category.id}
        data-parent-label={@category.title}
        class="ml-6 space-y-2 pt-2 empty:pt-0 group-data-dragging:empty:min-h-10 group-data-dragging:empty:rounded-box group-data-dragging:empty:border group-data-dragging:empty:border-dashed group-data-dragging:empty:border-base-300"
      >
        <.category_row
          :for={child <- @category.children}
          category={child}
          open={@open}
          groups={@groups}
          permissions={@permissions}
          sub
        />
      </ol>
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

      <div
        id="category-order"
        phx-hook="Sortable"
        data-event="place"
        data-msg-grabbed={gettext("%{item} picked up, position %{position} of %{count}.", slots())}
        data-msg-moved={gettext("%{item}: position %{position} of %{count}.", slots())}
        data-msg-moved-into={gettext("%{item} is now in %{parent}, position %{position} of %{count}.", slots())}
        data-msg-dropped={gettext("%{item} dropped at position %{position} of %{count}.", slots())}
        data-msg-cancelled={gettext("Move cancelled. %{item} is back at position %{position} of %{count}.", slots())}
        data-msg-failed={gettext("%{item} couldn't be moved there.", slots())}
        class="group"
      >
        <p id="category-order-help" class="mb-3 text-sm text-base-content/70">
          {gettext("Drag a category by its handle to reorder it, or into another category to make it a subcategory. With the keyboard: focus the handle, press Space to pick it up, the arrow keys to move it and Space to drop it, or Escape to cancel.")}
        </p>
        <ol id="categories" data-sortable-list data-parent="" class="space-y-2">
          <.category_row
            :for={category <- @tree}
            category={category}
            open={@open}
            groups={@groups}
            permissions={@permissions}
          />
        </ol>
        <div id="category-order-status" data-sortable-status role="status" aria-live="polite" class="sr-only" phx-update="ignore"></div>
      </div>
    </Layouts.app>
    """
  end
end
