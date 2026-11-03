defmodule FireflyWeb.StaffLive.Users do
  @moduledoc """
  The users admin (staff only; see `Firefly.Accounts.UserAdmin`): every
  account, filtered (all, active, new, staff, suspended, silenced, waiting
  for approval) and searched by username, name, email or IP address, 50 a
  page. The filter, search and page are in the URL. Each account opens
  its admin page (`FireflyWeb.StaffLive.User`); accounts waiting for
  approval can be approved or rejected right here.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Accounts
  alias Firefly.Accounts.{User, UserAdmin}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :view_users) do
      {:ok, assign(socket, :page_title, gettext("Users"))}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "filter" => if(params["filter"] in UserAdmin.filters(), do: params["filter"], else: "all"),
      "q" => String.trim(params["q"] || "")
    }

    page =
      case Integer.parse(params["page"] || "") do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    {:noreply,
     socket
     |> assign(:params, filters)
     |> assign(:page, UserAdmin.list(filters, page))
     |> assign(:pending_count, UserAdmin.pending_count())}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/staff/users?#{%{socket.assigns.params | "q" => q}}")}
  end

  def handle_event(event, %{"id" => id}, socket) when event in ["approve", "reject"] do
    staff = socket.assigns.current_user
    user = Accounts.get_user!(id)

    with true <- can?(staff, :approve_user),
         {:ok, user} <- decide(event, user, staff) do
      message =
        if event == "approve",
          do: gettext("Approved @%{username}.", username: user.username),
          else: gettext("Rejected and deleted the account.")

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> assign(:page, UserAdmin.list(socket.assigns.params, socket.assigns.page.page_number))
       |> assign(:pending_count, UserAdmin.pending_count())}
    else
      false -> {:noreply, put_flash(socket, :error, denied_message(staff))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}
    end
  end

  defp decide("approve", user, staff), do: UserAdmin.approve(user, staff)
  defp decide("reject", user, staff), do: UserAdmin.reject(user, staff)

  defp filter_label("all"), do: gettext("All")
  defp filter_label("active"), do: gettext("Active")
  defp filter_label("new"), do: gettext("New")
  defp filter_label("staff"), do: gettext("Staff")
  defp filter_label("suspended"), do: gettext("Suspended")
  defp filter_label("silenced"), do: gettext("Silenced")
  defp filter_label("pending"), do: gettext("Waiting for approval")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Users")} navigate={~p"/staff/users"}>
        <:subtitle>{gettext("Find an account to manage it. Every change is recorded in the staff log.")}</:subtitle>
      </.page_header>

      <div role="tablist" id="user-filters" class="tabs tabs-box w-fit flex-wrap">
        <.link
          :for={filter <- UserAdmin.filters()}
          patch={~p"/staff/users?#{%{filter: filter, q: @params["q"]}}"}
          role="tab"
          id={"filter-" <> filter}
          class={["tab", @params["filter"] == filter && "tab-active"]}
          aria-selected={to_string(@params["filter"] == filter)}
        >
          {filter_label(filter)}
          <span :if={filter == "pending" and @pending_count > 0} class="badge badge-sm badge-warning ml-1">
            {@pending_count}
          </span>
        </.link>
      </div>

      <form id="user-search" phx-submit="search" phx-change="search" role="search">
        <label class="input w-full">
          <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
          <input
            type="search"
            name="q"
            value={@params["q"]}
            phx-debounce="300"
            placeholder={gettext("Username, name, email or IP address")}
            aria-label={gettext("Search users")}
          />
        </label>
      </form>

      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table id="users" class="table">
          <thead>
            <tr>
              <th>{gettext("User")}</th>
              <th>{gettext("Email")}</th>
              <th>{gettext("Trust level")}</th>
              <th>{gettext("Last seen")}</th>
              <th>{gettext("Joined")}</th>
              <th><span class="sr-only">{gettext("Actions")}</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@page.entries == []}>
              <td colspan="6" class="text-base-content/70">{gettext("No users match.")}</td>
            </tr>
            <tr :for={user <- @page.entries} id={"user-#{user.id}"}>
              <td>
                <div class="flex items-center gap-2">
                  <.avatar user={user} size="size-8" />
                  <div>
                    <.link navigate={~p"/staff/users/#{user.id}"} class="link font-medium">{user.username}</.link>
                    <p class="text-xs text-base-content/70">{user.name}</p>
                    <div class="flex flex-wrap gap-1">
                      <span :if={User.pending_approval?(user)} class="badge badge-xs badge-warning">{gettext("pending")}</span>
                      <span :if={User.suspended?(user)} class="badge badge-xs badge-error">{gettext("suspended")}</span>
                      <span :if={User.silenced?(user)} class="badge badge-xs badge-warning">{gettext("silenced")}</span>
                    </div>
                  </div>
                </div>
              </td>
              <td class="text-sm">{user.email}</td>
              <td>{user.trust_level}</td>
              <td>
                <.time_ago :if={user.last_seen_at} id={"seen-#{user.id}"} at={user.last_seen_at} class="text-sm" />
                <span :if={!user.last_seen_at} class="text-sm text-base-content/60">{gettext("never")}</span>
              </td>
              <td><.time_ago id={"joined-#{user.id}"} at={user.inserted_at} class="text-sm" /></td>
              <td class="whitespace-nowrap">
                <%= if User.pending_approval?(user) and can?(@current_user, :approve_user) do %>
                  <button phx-click="approve" phx-value-id={user.id} class="btn btn-xs btn-primary">
                    {gettext("Approve")}
                  </button>
                  <button
                    phx-click="reject"
                    phx-value-id={user.id}
                    data-confirm={gettext("Reject and delete this account?")}
                    class="btn btn-xs btn-ghost"
                  >
                    {gettext("Reject")}
                  </button>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} path={~p"/staff/users"} params={@params} />
    </Layouts.app>
    """
  end
end
