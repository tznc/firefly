defmodule FirestormWeb.Web.MessageLive.Index do
  @moduledoc "The current user's private conversations (the inbox), unread ones highlighted."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Messages

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Messages")}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:page, params["page"]) |> load()}
  end

  @doc false
  def notifications_changed(socket), do: load(socket)

  defp load(socket),
    do: assign(socket, :inbox, Messages.inbox(socket.assigns.current_user, socket.assigns.page))

  defp others(conversation, user),
    do: for(p <- conversation.participants, p.user_id != user.id, do: p.user)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Messages">
        <:actions>
          <.link navigate={~p"/messages/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-pencil-square" class="size-4" /> New message
          </.link>
        </:actions>
      </.page_header>

      <ol id="conversations" class="list rounded-box border border-base-300 bg-base-100">
        <li :if={@inbox.entries == []} class="list-row text-base-content/60">
          No messages yet.
        </li>
        <li
          :for={conversation <- @inbox.entries}
          id={"conversation-#{conversation.id}"}
          class={["list-row items-center", conversation.unread_count > 0 && "unread bg-primary/5"]}
        >
          <div class="avatar-group -space-x-3">
            <.avatar :for={user <- others(conversation, @current_user)} user={user} size="size-8" />
          </div>
          <div class="list-col-grow min-w-0">
            <.link
              navigate={~p"/messages/#{conversation.id}"}
              class={["hover:text-primary", conversation.unread_count > 0 && "font-semibold"]}
            >
              {conversation.title}
            </.link>
            <p class="truncate text-sm text-base-content/60">
              with {Enum.map_join(others(conversation, @current_user), ", ", &"@#{&1.username}")}
            </p>
          </div>
          <span
            :if={conversation.unread_count > 0}
            class="badge badge-primary badge-sm"
            title="Unread messages"
          >
            {conversation.unread_count} new
          </span>
          <.time_ago id={"conversation-#{conversation.id}-time"} at={conversation.last_message_at} />
        </li>
      </ol>

      <.pagination page={@inbox} path={~p"/messages"} />
    </Layouts.app>
    """
  end
end
