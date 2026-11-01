defmodule FirestormWeb.Web.CategoryLive.Index do
  @moduledoc "Lists every category; updates live as categories change."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Forums.subscribe("forums:categories")

    {:ok,
     socket
     |> assign(:page_title, "Categories")
     |> assign(:categories, Forums.list_category_tree())}
  end

  @impl true
  def handle_info({_event, _category}, socket) do
    {:noreply, assign(socket, :categories, Forums.list_category_tree())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Categories" navigate={~p"/categories"}>
        <:actions :if={can?(@current_user, :manage_category)}>
          <.link navigate={~p"/categories/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> New Category
          </.link>
        </:actions>
      </.page_header>

      <ol id="categories" class="grid gap-3 sm:grid-cols-2">
        <li :if={@categories == []} class="text-base-content/60">No categories yet.</li>
        <li
          :for={category <- @categories}
          id={"category-#{category.id}"}
          class="card border border-base-300 bg-base-100 transition hover:border-primary"
        >
          <div class="card-body gap-2 p-4">
            <.link navigate={~p"/categories/#{category}"} class="flex items-center gap-3">
              <span class="size-3 rounded-full" style={"background-color: #{category_color(category)}"} />
              <h2 class="card-title text-base">{category.title}</h2>
            </.link>
            <p :if={category.description} class="text-sm text-base-content/70">
              {category.description}
            </p>
            <div :if={category.children != []} class="flex flex-wrap gap-1">
              <.category_badge :for={child <- category.children} category={child} />
            </div>
          </div>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
