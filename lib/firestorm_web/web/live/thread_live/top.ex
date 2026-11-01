defmodule FirestormWeb.Web.ThreadLive.Top do
  @moduledoc """
  The most active threads in a period (by posts in that period). Not live:
  period rankings don't need to follow every post, and re-ranking for every
  viewer on every post anywhere would be costly.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Top")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    period = if params["period"] in Forums.top_periods(), do: params["period"], else: "week"
    {:noreply, socket |> assign(:period, period) |> load()}
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
