defmodule FireflyWeb.CategoryLive.Show do
  @moduledoc """
  A category's threads, most recently active first; updates live. Signed-in
  users can act on several at once (see `FireflyWeb.BulkThreads`).
  """
  use FireflyWeb, :live_view

  alias Firefly.Discussion
  alias Firefly.Notifications.Subscriptions

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    category = Discussion.get_category_with_family!(id, socket.assigns.current_user)
    if connected?(socket), do: Discussion.subscribe("forums:category:#{category.id}")

    {:ok,
     socket
     |> assign(:page_title, category.title)
     |> assign(:category, category)
     |> FireflyWeb.SEO.assign(%{
       title: category.title,
       description: category.description,
       canonical: Firefly.URLs.category_url(category),
       noindex: category.restricted or not Firefly.SEO.indexable?()
     })
     |> assign(:level, Subscriptions.category_level(socket.assigns.current_user, category))
     |> load_threads()
     |> FireflyWeb.BulkThreads.init()}
  end

  @impl true
  def handle_info({_event, _thread}, socket), do: {:noreply, load_threads(socket)}

  @impl true
  def handle_event("set_level", %{"level" => level}, %{assigns: %{current_user: user}} = socket)
      when not is_nil(user) and level in ["watching", "tracking", "normal", "muted"] do
    {:ok, _} = Subscriptions.set_category_level(user, socket.assigns.category, level)
    {:noreply, socket |> assign(:level, level) |> load_threads()}
  end

  # Unknown levels, or an anonymous viewer.
  def handle_event("set_level", _params, socket), do: {:noreply, socket}

  def handle_event("bulk_" <> _ = event, params, socket),
    do: FireflyWeb.BulkThreads.handle_event(event, params, socket, &load_threads/1)

  def handle_event("delete", _params, socket) do
    if can?(socket.assigns.current_user, :manage_category) do
      {:ok, _} = Discussion.delete_category(socket.assigns.category, socket.assigns.current_user)

      {:noreply,
       socket
       |> put_flash(:info, "Category deleted successfully.")
       |> push_navigate(to: ~p"/categories")}
    else
      {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
    end
  end

  defp load_threads(socket) do
    assign(
      socket,
      :threads,
      Discussion.recent_threads(socket.assigns.category, socket.assigns.current_user)
    )
  end

  # The groups that can read the category (its own, else its parent's).
  defp restricted_to(%{roles: [_ | _] = roles}), do: Enum.map_join(roles, ", ", & &1.name)

  defp restricted_to(%{parent: %{} = parent}),
    do: parent |> Firefly.Repo.preload(:roles) |> restricted_to()

  defp restricted_to(_category), do: "some groups"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={@category.title} navigate={~p"/categories/#{@category}"}>
        <:subtitle :if={@category.restricted}>
          <span id="category-restricted">
            <.lock /> Only {restricted_to(@category)} can see this category.
          </span>
        </:subtitle>
        <:actions>
          <.level_picker :if={@current_user} id="category-level" level={@level} />
          <.link navigate={~p"/categories/#{@category}/threads/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> New Thread
          </.link>
          <.link
            :if={can?(@current_user, :manage_category)}
            navigate={~p"/categories/#{@category}/edit"}
            class="btn btn-ghost btn-sm"
          >
            Edit
          </.link>
          <button
            :if={can?(@current_user, :manage_category)}
            phx-click="delete"
            data-confirm="Delete this category and all of its threads?"
            class="btn btn-ghost btn-sm text-error"
          >
            Delete
          </button>
        </:actions>
      </.page_header>

      <div :if={@category.parent || @category.description || @category.children != []} class="space-y-2">
        <p :if={@category.parent} id="parent-category" class="text-sm text-base-content/70">
          In <.category_badge category={@category.parent} />
        </p>
        <p :if={@category.description} id="category-description" class="text-base-content/80">
          {@category.description}
        </p>
        <div :if={@category.children != []} id="subcategories" class="flex flex-wrap gap-1">
          <.category_badge :for={child <- @category.children} category={child} />
        </div>
      </div>

      <FireflyWeb.BulkThreads.bar
        selected={@selected}
        actions={@bulk_actions}
        categories={@bulk_categories}
      />
      <.thread_list threads={@threads} selected={@selected} />
    </Layouts.app>
    """
  end
end
