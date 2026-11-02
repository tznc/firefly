defmodule FirestormWeb.Web.MessageLive.New do
  @moduledoc "Starts a private conversation with one or more users (`?to=username` fills in the first)."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Messages, Posting}
  alias FirestormWeb.Web.Editor

  @impl true
  def mount(params, _session, socket) do
    to = if is_binary(params["to"]), do: "@" <> params["to"], else: ""

    {:ok,
     socket
     |> assign(:page_title, "New message")
     |> assign(:form, to_form(Messages.change_conversation(%{"recipients" => to})))
     |> Editor.allow_attachments(&handle_progress/3)
     |> Editor.mention_search()}
  end

  @impl true
  def handle_event("validate", %{"conversation" => params}, socket) do
    changeset = Messages.change_conversation(params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"conversation" => params}, socket) do
    user = socket.assigns.current_user

    with :ok <- Posting.check(user, :new_conversation),
         {:ok, conversation} <- Messages.start_conversation(user, params) do
      {:noreply,
       socket
       |> put_flash(:info, "Message sent.")
       |> push_navigate(to: ~p"/messages/#{conversation.id}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Posting.message(reason))}
    end
  end

  defp handle_progress(:attachment, entry, socket) do
    Editor.attachment_progress(socket, entry, fn socket, markdown ->
      params =
        Map.update(socket.assigns.form.params, "body", markdown, &Editor.append(&1, markdown))

      {:noreply, assign(socket, :form, to_form(Messages.change_conversation(params)))}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="New message">
        <:subtitle>Only the people you add can read it.</:subtitle>
      </.page_header>

      <.form for={@form} id="conversation-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input
          field={@form[:recipients]}
          type="text"
          label="To"
          placeholder="@username, @another"
        />
        <.input field={@form[:title]} type="text" label="Title" placeholder="What's it about?" />
        <Editor.body_editor
          field={@form[:body]}
          uploads={@uploads}
          user={@current_user}
          placeholder="Type your message. Use markdown syntax."
        />
        <div class="flex justify-end gap-2">
          <.link navigate={~p"/messages"} class="btn btn-ghost">Cancel</.link>
          <.button variant="primary" phx-disable-with="Sending...">
            <.icon name="hero-paper-airplane" class="size-4" /> Send
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
