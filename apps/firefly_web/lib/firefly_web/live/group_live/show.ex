defmodule FireflyWeb.GroupLive.Show do
  @moduledoc """
  A group's page (see `Firefly.Groups`), for those its visibility
  allows, with tabs: About (`/groups/:name`), Members, Activity (its
  members' latest posts the viewer may read), Messages (the group's inbox,
  for members) and Requests (for owners and admins).

  Members join, ask to join, accept invitations, leave and choose how they
  hear about the inbox here. Owners and admins add, remove and invite
  members, decide on requests and edit the About text; admins also make
  members owners.
  """
  use FireflyWeb, :live_view

  alias Firefly.{Accounts, Groups, Messaging}
  alias Firefly.Groups.RoleMembership

  @level_labels %{
    "watching" => "Watching: every message, by email too",
    "tracking" => "Tracking: every message",
    "normal" => "Normal: new conversations",
    "muted" => "Muted: nothing"
  }

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    group = Groups.get_by_name(name)

    if group && Groups.visible?(group, socket.assigns.current_user) do
      {:ok, socket |> assign(:page_title, group.name) |> load(group)}
    else
      {:ok, socket |> put_flash(:error, "No such group.") |> push_navigate(to: ~p"/groups")}
    end
  end

  defp load(socket, group) do
    user = socket.assigns.current_user

    assign(socket,
      group: group,
      member?: Groups.member?(group, user),
      manager?: Groups.manager?(group, user),
      admin?: user != nil and Accounts.admin?(user),
      pending: Groups.pending_for(group, user),
      level: Groups.notification_level(group, user),
      members: Groups.members(group),
      requests: if(Groups.manager?(group, user), do: Groups.pending(group), else: []),
      can_message?: Groups.can_message?(group, user),
      description_form: to_form(%{"description" => group.description || ""}, as: :group)
    )
  end

  defp reload(socket), do: load(socket, Groups.get_group!(socket.assigns.group.id))

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if socket.assigns.live_action == :tab, do: params["tab"], else: "about"

    if tab in tabs(socket.assigns) do
      {:noreply, socket |> assign(:tab, tab) |> load_tab(tab, params)}
    else
      {:noreply, push_patch(socket, to: ~p"/groups/#{socket.assigns.group.name}")}
    end
  end

  defp tabs(assigns) do
    ["about", "members", "activity"] ++
      if(assigns.member?, do: ["messages"], else: []) ++
      if(assigns.manager?, do: ["requests"], else: [])
  end

  defp load_tab(socket, "activity", _params),
    do: assign(socket, :posts, Groups.activity(socket.assigns.group, socket.assigns.current_user))

  defp load_tab(socket, "messages", params),
    do: assign(socket, :inbox, Messaging.group_inbox(socket.assigns.group, params["page"]))

  defp load_tab(socket, _tab, _params), do: socket

  @impl true
  def handle_event(event, params, %{assigns: %{current_user: nil}} = socket)
      when is_binary(event) and is_map(params),
      do: {:noreply, put_flash(socket, :error, "Log in first.")}

  def handle_event("join", params, socket) do
    %{group: group, current_user: user} = socket.assigns

    case Groups.join(group, user, params["message"]) do
      {:ok, :joined} -> done(socket, "You joined #{group.name}.")
      {:ok, :requested} -> done(socket, "You asked to join #{group.name}.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("leave", _params, socket) do
    %{group: group, current_user: user} = socket.assigns

    case Groups.remove_member(group, user, user) do
      {:ok, _} -> done(socket, "You left #{group.name}.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("answer_invite", %{"accept" => accept}, socket) do
    %{group: group, current_user: user} = socket.assigns

    case Groups.answer_invite(group, user, accept == "true") do
      {:ok, :joined} -> done(socket, "You joined #{group.name}.")
      {:ok, :declined} -> done(socket, "Invitation declined.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("set_level", %{"level" => level}, socket) do
    case Groups.set_notification_level(socket.assigns.group, socket.assigns.current_user, level) do
      :ok -> done(socket, "Notification level saved.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("add_member", %{"username" => username}, socket) do
    case Groups.add_member(socket.assigns.group, username, socket.assigns.current_user) do
      {:ok, user} -> done(socket, "Added @#{user.username}.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("invite", %{"username" => username}, socket) do
    case Groups.invite(socket.assigns.group, username, socket.assigns.current_user) do
      {:ok, user} -> done(socket, "Invited @#{user.username}.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    member = Accounts.get_user!(user_id)

    case Groups.remove_member(socket.assigns.group, member, socket.assigns.current_user) do
      {:ok, _} -> done(socket, "Removed @#{member.username}.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("set_owner", %{"user_id" => user_id, "owner" => owner}, socket) do
    member = Accounts.get_user!(user_id)
    %{group: group, current_user: admin} = socket.assigns

    case Groups.set_owner(group, member, owner == "true", admin) do
      {:ok, _} -> done(socket, "Owners updated.")
      {:error, reason} -> failed(socket, reason)
    end
  end

  def handle_event("decide", %{"request_id" => id, "approve" => approve}, socket) do
    %{group: group, current_user: actor} = socket.assigns

    case Groups.decide(group, id, approve == "true", actor) do
      {:ok, user} ->
        done(
          socket,
          if(approve == "true", do: "Added @#{user.username}.", else: "Request denied.")
        )

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  def handle_event("save_description", %{"group" => params}, socket) do
    %{group: group, current_user: actor} = socket.assigns

    case Groups.update_description(group, params, actor) do
      {:ok, _group} -> done(socket, "Saved.")
      {:error, %Ecto.Changeset{}} -> failed(socket, :too_long)
      {:error, reason} -> failed(socket, reason)
    end
  end

  defp done(socket, message), do: {:noreply, socket |> reload() |> put_flash(:info, message)}

  defp failed(socket, :too_long),
    do: {:noreply, put_flash(socket, :error, "The description is too long.")}

  defp failed(socket, reason), do: {:noreply, put_flash(socket, :error, Groups.message(reason))}

  defp tab_path(group, "about"), do: ~p"/groups/#{group.name}"
  defp tab_path(group, tab), do: ~p"/groups/#{group.name}/#{tab}"

  defp tab_label("about"), do: "About"
  defp tab_label("members"), do: "Members"
  defp tab_label("activity"), do: "Activity"
  defp tab_label("messages"), do: "Messages"
  defp tab_label("requests"), do: "Requests"

  defp level_options, do: Enum.map(RoleMembership.levels(), &{@level_labels[&1], &1})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={@group.name}>
        <:subtitle>{length(@members)} {if length(@members) == 1, do: "member", else: "members"}</:subtitle>
        <:actions>
          <.link
            :if={@can_message?}
            navigate={~p"/messages/new?to=@#{@group.name}"}
            class="btn btn-sm"
          >
            <.icon name="hero-envelope" class="size-4" /> Message
          </.link>
          <button
            :if={@current_user && !@member? && !@pending && @group.membership == "open"}
            phx-click="join"
            class="btn btn-primary btn-sm"
          >
            Join
          </button>
          <span :if={@pending && @pending.kind == "request"} class="badge badge-ghost">
            Request sent
          </span>
          <button
            :if={@member? and @group.name != "admin"}
            phx-click="leave"
            data-confirm={"Leave #{@group.name}?"}
            class="btn btn-ghost btn-sm"
          >
            Leave
          </button>
        </:actions>
      </.page_header>

      <div :if={@pending && @pending.kind == "invite"} id="invitation" class="alert alert-info">
        <span>You're invited to join {@group.name}.</span>
        <button phx-click="answer_invite" phx-value-accept="true" class="btn btn-primary btn-sm">
          Accept
        </button>
        <button phx-click="answer_invite" phx-value-accept="false" class="btn btn-ghost btn-sm">
          Decline
        </button>
      </div>

      <.form
        :if={@current_user && !@member? && !@pending && @group.membership == "request"}
        for={%{}}
        id="request-form"
        phx-submit="join"
        class="flex flex-wrap items-end gap-2"
      >
        <div class="w-72">
          <.input name="message" value="" label="Why you'd like to join (optional)" maxlength="200" />
        </div>
        <button class="btn btn-primary btn-sm mb-2">Ask to join</button>
      </.form>

      <div role="tablist" class="tabs tabs-border" id="group-tabs">
        <.link
          :for={tab <- tabs(assigns)}
          patch={tab_path(@group, tab)}
          role="tab"
          class={["tab", @tab == tab && "tab-active"]}
        >
          {tab_label(tab)}
          <span :if={tab == "requests" and @requests != []} class="badge badge-primary badge-xs ml-1">
            {length(@requests)}
          </span>
        </.link>
      </div>

      <div :if={@tab == "about"} id="group-about" class="space-y-4">
        <p :if={@group.description} class="whitespace-pre-line">{@group.description}</p>
        <p :if={!@group.description} class="text-base-content/60">No description yet.</p>
        <.form
          :if={@manager?}
          for={@description_form}
          id="description-form"
          phx-submit="save_description"
          class="space-y-2"
        >
          <.input field={@description_form[:description]} type="textarea" label="About" rows="4" />
          <button class="btn btn-sm">Save</button>
        </.form>
      </div>

      <div :if={@tab == "members"} class="space-y-4">
        <ul id="group-members" class="list rounded-box border border-base-300 bg-base-100">
          <li :for={{user, owner?} <- @members} id={"member-#{user.id}"} class="list-row items-center">
            <.avatar user={user} size="size-8" />
            <div class="list-col-grow">
              <.link navigate={~p"/users/#{user}"} class="font-medium hover:text-primary">
                @{user.username}
              </.link>
              <span :if={owner?} class="badge badge-sm ml-1">Owner</span>
            </div>
            <button
              :if={@admin?}
              phx-click="set_owner"
              phx-value-user_id={user.id}
              phx-value-owner={to_string(!owner?)}
              class="btn btn-ghost btn-xs"
            >
              {if owner?, do: "Remove owner", else: "Make owner"}
            </button>
            <button
              :if={@manager? and user.id != @current_user.id}
              phx-click="remove_member"
              phx-value-user_id={user.id}
              data-confirm={"Remove @#{user.username} from #{@group.name}?"}
              class="btn btn-ghost btn-xs"
              aria-label={"Remove #{user.username}"}
            >
              Remove
            </button>
          </li>
        </ul>
        <div :if={@manager?} class="flex flex-wrap gap-4">
          <form id="add-member-form" phx-submit="add_member" class="flex items-center gap-2">
            <label for="add-member-username" class="sr-only">Add a member</label>
            <input type="text" id="add-member-username" name="username" placeholder="username" class="input input-sm" />
            <button class="btn btn-sm">Add member</button>
          </form>
          <form id="invite-form" phx-submit="invite" class="flex items-center gap-2">
            <label for="invite-username" class="sr-only">Invite someone</label>
            <input type="text" id="invite-username" name="username" placeholder="username" class="input input-sm" />
            <button class="btn btn-sm">Invite</button>
          </form>
        </div>
      </div>

      <div :if={@tab == "activity"}>
        <ul id="group-activity" class="list rounded-box border border-base-300 bg-base-100">
          <li :if={@posts == []} class="list-row text-base-content/60">No posts yet.</li>
          <li :for={post <- @posts} id={"activity-post-#{post.id}"} class="list-row">
            <.avatar user={post.user} size="size-8" />
            <div class="list-col-grow min-w-0">
              <.link
                navigate={~p"/categories/#{post.thread.category_id}/threads/#{post.thread_id}" <> "#post-#{post.id}"}
                class="font-medium hover:text-primary"
              >
                {post.thread.title}
              </.link>
              <p class="truncate text-sm text-base-content/60">@{post.user.username}: {post.body}</p>
            </div>
            <.time_ago id={"activity-#{post.id}-time"} at={post.inserted_at} />
          </li>
        </ul>
      </div>

      <div :if={@tab == "messages"} class="space-y-4">
        <.form for={%{}} id="group-level-form" phx-change="set_level" class="max-w-sm">
          <.input name="level" type="select" label="Messages to this group" value={@level} options={level_options()} />
        </.form>
        <ol id="group-inbox" class="list rounded-box border border-base-300 bg-base-100">
          <li :if={@inbox.entries == []} class="list-row text-base-content/60">No messages yet.</li>
          <li :for={conversation <- @inbox.entries} id={"conversation-#{conversation.id}"} class="list-row items-center">
            <div class="list-col-grow min-w-0">
              <.link navigate={~p"/messages/#{conversation.id}"} class="hover:text-primary">
                {conversation.title}
              </.link>
              <p class="truncate text-sm text-base-content/60">
                {Enum.map_join(conversation.participants, ", ", &"@#{&1.user.username}")}
              </p>
            </div>
            <.time_ago id={"conversation-#{conversation.id}-time"} at={conversation.last_message_at} />
          </li>
        </ol>
        <.pagination page={@inbox} path={~p"/groups/#{@group.name}/messages"} />
      </div>

      <div :if={@tab == "requests"}>
        <ul id="group-requests" class="list rounded-box border border-base-300 bg-base-100">
          <li :if={@requests == []} class="list-row text-base-content/60">No pending requests.</li>
          <li :for={request <- @requests} id={"request-#{request.id}"} class="list-row items-center">
            <.avatar user={request.user} size="size-8" />
            <div class="list-col-grow">
              <span class="font-medium">@{request.user.username}</span>
              <span class="badge badge-sm ml-1">
                {if request.kind == "invite", do: "Invited", else: "Asked to join"}
              </span>
              <p :if={request.message} class="text-sm text-base-content/70">{request.message}</p>
            </div>
            <div :if={request.kind == "request"} class="flex gap-1">
              <button phx-click="decide" phx-value-request_id={request.id} phx-value-approve="true" class="btn btn-primary btn-xs">
                Approve
              </button>
              <button phx-click="decide" phx-value-request_id={request.id} phx-value-approve="false" class="btn btn-ghost btn-xs">
                Deny
              </button>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
