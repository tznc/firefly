defmodule FirestormWeb.Web.ThreadLive.Top do
  @moduledoc "The most active threads in a period (by posts in that period)."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Forums.subscribe("forums:threads")
    {:ok, assign(socket, :page_title, "Top")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = if params["period"] in Forums.top_periods(), do: params["period"], else: "week"
    {:noreply, socket |> assign(:period, period) |> load()}
  end

  @impl true
  def handle_info({event, _thread}, socket)
      when event in [:thread_created, :thread_updated, :thread_deleted, :thread_activity] do
    {:noreply, load(socket)}
  end

  defp load(socket) do
    assign(
      socket,
      :threads,
      Forums.top_threads(socket.assigns.period, socket.assigns.current_user)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.list_tabs current_path="/top" current_user={@current_user} />
      <div id="top-periods" class="join">
        <.link
          :for={period <- Forums.top_periods()}
          patch={~p"/top?#{[period: period]}"}
          class={["btn btn-sm join-item", @period == period && "btn-active"]}
        >
          {String.capitalize(period)}
        </.link>
      </div>
      <.thread_list threads={@threads} empty="No activity in this period." />
    </Layouts.app>
    """
  end
end
