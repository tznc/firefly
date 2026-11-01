defmodule FirestormWeb.Web.TagLive.Index do
  @moduledoc "Every tag in use, with how many threads have it."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tags")
     |> assign(:tags, Forums.list_tags())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Tags" navigate={~p"/tags"} />

      <ul id="tags" class="flex flex-wrap gap-2">
        <li :if={@tags == []} class="text-base-content/60">No tags yet.</li>
        <li :for={tag <- @tags} id={"tag-#{tag.name}"}>
          <.link navigate={~p"/tags/#{tag.name}"} class="btn btn-sm btn-ghost border-base-300">
            <.icon name="hero-tag" class="size-4" />
            {tag.name} <span class="badge badge-sm">{tag.threads_count}</span>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
