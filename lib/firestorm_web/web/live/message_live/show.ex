defmodule FirestormWeb.Web.MessageLive.Show do
  @moduledoc """
  A private conversation: its messages (new ones appear live), a reply box,
  its participants, adding people and leaving. Only participants get in (the
  `:view_conversation` policy); viewing it marks it read.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Messages, Posting}
  alias FirestormWeb.Forums.Message
  alias FirestormWeb.Web.Editor

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    conversation = Messages.get_conversation(id)

    if conversation && can?(user, :view_conversation, conversation) do
      if connected?(socket), do: Messages.subscribe(conversation)

      {:ok,
       socket
       |> assign(:page_title, conversation.title)
       |> assign(:conversation, conversation)
       |> assign(:last_read_id, Messages.last_read_message_id(conversation, user))
       |> assign(:add_form, to_form(%{"usernames" => ""}, as: :add))
       |> assign_reply_form(%{})
       |> load()
       |> Editor.allow_attachments(&handle_progress/3)
       |> Editor.mention_search()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Conversation not found.")
       |> push_navigate(to: ~p"/messages")}
    end
  end

  @impl true
  def handle_info({:message_created, _message}, socket), do: {:noreply, load(socket)}

  def handle_info({:participants_changed, _conversation}, socket) do
    if can?(socket.assigns.current_user, :view_conversation, socket.assigns.conversation),
      do: {:noreply, load(socket)},
      else: {:noreply, push_navigate(socket, to: ~p"/messages")}
  end

  @impl true
  def handle_event("validate", %{"message" => params}, socket) do
    changeset = Message.changeset(%Message{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("reply", %{"message" => params}, socket) do
    %{conversation: conversation, current_user: user} = socket.assigns

    with :ok <- Posting.check(user),
         {:ok, _message} <- Messages.reply(conversation, user, %{body: params["body"]}) do
      {:noreply, socket |> assign_reply_form(%{}) |> load()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, denied_message(user))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Posting.message(reason))}
    end
  end

  def handle_event("add", %{"add" => %{"usernames" => usernames}}, socket) do
    %{conversation: conversation, current_user: user} = socket.assigns

    with true <- can?(user, :add_participants, conversation),
         {:ok, added} <- Messages.add_participants(conversation, user, usernames) do
      {:noreply,
       socket
       |> put_flash(:info, "Added #{Enum.map_join(added, ", ", &"@#{&1.username}")}.")
       |> assign(:add_form, to_form(%{"usernames" => ""}, as: :add))
       |> load()}
    else
      false ->
        {:noreply, put_flash(socket, :error, denied_message(user))}

      {:error, message} ->
        {:noreply,
         assign(
           socket,
           :add_form,
           to_form(%{"usernames" => usernames},
             as: :add,
             errors: [usernames: {message, []}],
             action: :validate
           )
         )}
    end
  end

  def handle_event("leave", _params, socket) do
    :ok = Messages.leave(socket.assigns.conversation, socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, "You left the conversation.")
     |> push_navigate(to: ~p"/messages")}
  end

  defp handle_progress(:attachment, entry, socket) do
    if entry.done? do
      markdown = Editor.consume_attachment(socket, entry)
      body = Editor.append(socket.assigns.form[:body].value, markdown)
      {:noreply, assign_reply_form(socket, %{"body" => body})}
    else
      {:noreply, socket}
    end
  end

  defp assign_reply_form(socket, params),
    do: assign(socket, :form, to_form(Message.changeset(%Message{}, params)))

  defp load(socket) do
    %{conversation: conversation, current_user: user} = socket.assigns
    if connected?(socket), do: Messages.mark_read(conversation, user)

    socket
    |> assign(:messages, Messages.messages(conversation))
    |> assign(:participants, Messages.participants(conversation))
    |> assign(:can_add?, can?(user, :add_participants, conversation))
  end

  defp first_unread_id(_messages, nil), do: nil

  defp first_unread_id(messages, last_read_id),
    do: Enum.find_value(messages, &(&1.id > last_read_id && &1.id))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <header class="space-y-3">
        <.link navigate={~p"/messages"} class="link link-hover text-sm">
          <.icon name="hero-envelope" class="size-4" /> Messages
        </.link>
        <h1 class="flex items-center gap-2 text-2xl font-bold tracking-tight">
          <.icon name="hero-lock-closed" class="size-5 opacity-60" /> {@conversation.title}
        </h1>
        <div id="participants" class="flex flex-wrap items-center gap-2 text-sm">
          <.link
            :for={user <- @participants}
            navigate={~p"/users/#{user}"}
            class="badge badge-ghost gap-1"
          >
            <.avatar user={user} size="size-4" /> @{user.username}
          </.link>
          <button
            id="leave-conversation"
            phx-click="leave"
            data-confirm="Leave this conversation? You won't see it or hear about it again unless someone adds you back."
            class="btn btn-ghost btn-xs ml-auto"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Leave
          </button>
        </div>
        <.form
          :if={@can_add?}
          for={@add_form}
          id="add-participants-form"
          phx-submit="add"
          class="flex items-start gap-2"
        >
          <div class="flex-1">
            <.input field={@add_form[:usernames]} type="text" placeholder="@username" aria-label="Add people" />
          </div>
          <.button class="btn btn-sm mt-1">Add people</.button>
        </.form>
      </header>

      <ol id="messages" class="space-y-4">
        <li :for={message <- @messages}>
          <div
            :if={message.id == first_unread_id(@messages, @last_read_id)}
            id="new-messages-divider"
            class="divider divider-primary text-xs text-primary"
          >
            New since your last visit
          </div>
          <article id={"message-#{message.id}"} class="card border border-base-300 bg-base-100">
            <div class="card-body gap-4 p-5">
              <header class="flex items-center gap-3 text-sm">
                <.avatar user={message.user} size="size-9" />
                <div>
                  <.link navigate={~p"/users/#{message.user}"} class="font-semibold hover:text-primary">
                    @{message.user.username}
                  </.link>
                  <div class="text-xs text-base-content/60">
                    <.time_ago id={"message-#{message.id}-time"} at={message.inserted_at} />
                  </div>
                </div>
              </header>
              <.markdown id={"message-#{message.id}-body"} body={message.body} />
            </div>
          </article>
        </li>
      </ol>

      <.form for={@form} id="reply-form" phx-change="validate" phx-submit="reply" class="space-y-4">
        <Editor.body_editor field={@form[:body]} uploads={@uploads} placeholder="Write a reply. Use markdown syntax." />
        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with="Sending...">
            <.icon name="hero-arrow-uturn-left" class="size-4" /> Reply
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
