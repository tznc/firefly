defmodule FireflyWeb.UserLive.Index do
  @moduledoc """
  The user directory (see `Firefly.Directory`): members with their
  stats for a period (tabs), searchable by name, sorted by any stat
  (clicking a column heading sorts by it; again flips the order),
  paginated. Everything is in the URL's query, so a view can be linked.
  """
  use FireflyWeb, :live_view

  alias Firefly.Directory

  @period_labels %{
    "all" => "All time",
    "year" => "Year",
    "month" => "Month",
    "week" => "Week",
    "day" => "Today"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Users")
     |> assign(:refreshed_at, Directory.refreshed_at())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = Map.take(params, ~w(period order asc name page))

    query = %{
      "period" => params["period"] || "all",
      "order" => params["order"] || "likes_received",
      "asc" => params["asc"] || "false",
      "name" => params["name"] || ""
    }

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:search_form, to_form(%{"name" => query["name"]}, as: :search))
     |> assign(:users_page, Directory.page(params))}
  end

  @impl true
  def handle_event("search", %{"search" => %{"name" => name}}, socket) do
    {:noreply, push_patch(socket, to: path(%{socket.assigns.query | "name" => name}))}
  end

  defp path(query) do
    query =
      query
      |> Enum.reject(fn {key, value} -> {key, value} in defaults() end)
      |> Map.new()

    if query == %{}, do: ~p"/users", else: ~p"/users?#{query}"
  end

  defp defaults,
    do: [{"period", "all"}, {"order", "likes_received"}, {"asc", "false"}, {"name", ""}]

  # Sorting by a new column starts descending (most first); the current
  # one flips.
  defp sort_path(query, column) do
    asc = if query["order"] == column and query["asc"] != "true", do: "true", else: "false"
    path(%{query | "order" => column, "asc" => asc})
  end

  defp period_label(period), do: @period_labels[period]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Users" navigate={~p"/users"}>
        <:subtitle :if={@refreshed_at}>
          Stats as of <.time_ago id="directory-refreshed" at={@refreshed_at} />; they refresh hourly.
        </:subtitle>
      </.page_header>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <div role="tablist" id="period-tabs" class="tabs tabs-border">
          <.link
            :for={period <- Directory.periods()}
            patch={path(%{@query | "period" => period})}
            role="tab"
            class={["tab", @query["period"] == period && "tab-active"]}
          >
            {period_label(period)}
          </.link>
        </div>
        <.form for={@search_form} id="directory-search" phx-change="search" phx-submit="search">
          <input
            type="search"
            name="search[name]"
            value={@search_form[:name].value}
            placeholder="Search by name"
            aria-label="Search users"
            phx-debounce="300"
            class="input input-sm"
          />
        </.form>
      </div>

      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table id="users" class="table table-sm">
          <thead>
            <tr>
              <th>User</th>
              <th :for={column <- Directory.columns()} class="text-right">
                <.link
                  patch={sort_path(@query, column)}
                  id={"sort-#{column}"}
                  class={["link-hover whitespace-nowrap", @query["order"] == column && "text-primary"]}
                >
                  {Directory.label(column)}
                  <span :if={@query["order"] == column}>
                    {if @query["asc"] == "true", do: "▲", else: "▼"}
                  </span>
                </.link>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@users_page.entries == []}>
              <td colspan={length(Directory.columns()) + 1} class="text-base-content/60">
                No users found.
              </td>
            </tr>
            <tr :for={%{user: user, stats: stats} <- @users_page.entries} id={"user-#{user.id}"}>
              <td>
                <.link navigate={~p"/users/#{user}"} class="flex items-center gap-2 hover:text-primary">
                  <.avatar user={user} size="size-8" />
                  <span class="min-w-0">
                    <span class="block truncate font-medium">{user.username}</span>
                    <span
                      :if={user.name && user.name != user.username}
                      class="block truncate text-xs text-base-content/60"
                    >
                      {user.name}
                    </span>
                  </span>
                </.link>
              </td>
              <td
                :for={column <- Directory.columns()}
                class={["text-right tabular-nums", "stat-#{column}"]}
              >
                {Map.fetch!(stats, String.to_existing_atom(column))}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination
        page={@users_page}
        path={~p"/users"}
        params={Map.new(Enum.reject(@query, &(&1 in defaults())))}
      />
    </Layouts.app>
    """
  end
end
