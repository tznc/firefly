defmodule FirestormWeb.Web.ThreadLive.Edit do
  @moduledoc "Renames a thread."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Thread

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    category = Forums.get_category!(category_id)
    thread = Forums.get_thread!(category, id)

    {:ok,
     socket
     |> assign(:page_title, "Edit #{thread.title}")
     |> assign(:category, category)
     |> assign(:thread, thread)
     |> assign(:form, to_form(Forums.change_thread(thread)))}
  end

  @impl true
  def handle_event("validate", %{"thread" => params}, socket) do
    changeset = Thread.changeset(socket.assigns.thread, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"thread" => params}, socket) do
    case Forums.update_thread(socket.assigns.thread, params) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> put_flash(:info, "Thread updated successfully.")
         |> push_navigate(to: ~p"/categories/#{socket.assigns.category}/threads/#{thread}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Edit Thread" />

      <.form for={@form} id="thread-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input field={@form[:title]} type="text" label="Title" />
        <div class="flex justify-end gap-2">
          <.link navigate={~p"/categories/#{@category}/threads/#{@thread}"} class="btn btn-ghost">
            Back
          </.link>
          <.button variant="primary" phx-disable-with="Saving...">Submit</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
