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
     |> assign(:categories, Forums.list_categories())}
  end

  @impl true
  def handle_info({_event, _category}, socket) do
    {:noreply, assign(socket, :categories, Forums.list_categories())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Categories" navigate={~p"/categories"}>
        <:actions>
          <.link navigate={~p"/categories/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> New Category
          </.link>
        </:actions>
      </.page_header>

      <ol id="categories" class="grid gap-3 sm:grid-cols-2">
        <li :if={@categories == []} class="text-base-content/60">No categories yet.</li>
        <li :for={category <- @categories} id={"category-#{category.id}"}>
          <.link
            navigate={~p"/categories/#{category}"}
            class="card border border-base-300 bg-base-100 transition hover:border-primary"
          >
            <div class="card-body flex-row items-center gap-3 p-4">
              <span
                class="size-3 rounded-full"
                style={"background-color: oklch(55% 0.13 #{category_color(category)})"}
              />
              <h2 class="card-title text-base">{category.title}</h2>
            </div>
          </.link>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
