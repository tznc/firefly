defmodule FireflyWeb.BadgeLive.Index do
  @moduledoc """
  The badges page: every enabled, listable badge by grouping, with how
  many members hold it, marking the ones the viewer has (see
  `Firefly.Badges`).
  """
  use FireflyWeb, :live_view

  alias Firefly.Badges
  alias Firefly.Badges.Badge

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Badges")
     |> assign(:groups, Badges.listing())
     |> assign(:held, Badges.held_ids(socket.assigns.current_user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Badges" navigate={~p"/badges"}>
        <:subtitle>Earned for taking part, or given by staff.</:subtitle>
      </.page_header>

      <p :if={@groups == []} class="text-base-content/70">No badges yet.</p>

      <section :for={{grouping, badges} <- @groups} id={"badges-#{grouping}"} class="space-y-2">
        <h2 class="font-semibold">{Badge.grouping_label(grouping)}</h2>
        <ul class="grid gap-2 sm:grid-cols-2">
          <li :for={badge <- badges} id={"badge-#{badge.id}"}>
            <.link
              navigate={~p"/badges/#{badge.id}"}
              class="flex items-start gap-3 rounded-box border border-base-300 bg-base-100 p-3 hover:border-primary"
            >
              <.badge_icon badge={badge} />
              <span class="min-w-0 flex-1">
                <span class="font-semibold">{badge.name}</span>
                <span :if={MapSet.member?(@held, badge.id)} class="badge badge-success badge-xs ml-1">
                  Yours
                </span>
                <span class="block text-sm text-base-content/70">{badge.description}</span>
              </span>
              <span class="text-sm text-base-content/60" title="Members with it">
                {badge.grant_count}
              </span>
            </.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
