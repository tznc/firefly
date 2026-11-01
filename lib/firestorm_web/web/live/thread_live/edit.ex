defmodule FirestormWeb.Web.ThreadLive.Edit do
  @moduledoc "Renames a thread and changes its tags."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.Thread

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    category = Forums.get_visible_category!(category_id, socket.assigns.current_user)
    thread = Forums.get_visible_thread!(category, id, socket.assigns.current_user)

    if can?(socket.assigns.current_user, :update_thread, thread),
      do: mount_form(socket, category, thread),
      else:
        {:ok,
         socket
         |> put_flash(:error, denied_message(socket.assigns.current_user))
         |> push_navigate(to: ~p"/categories/#{category}/threads/#{thread}")}
  end

  defp mount_form(socket, category, thread) do
    {:ok,
     socket
     |> assign(:page_title, "Edit #{thread.title}")
     |> assign(:category, category)
     |> assign(:thread, thread)
     |> assign(
       :tags,
       thread |> Repo.preload(:tags) |> Map.get(:tags) |> Enum.map_join(", ", & &1.name)
     )
     |> assign(:form, to_form(Forums.change_thread(thread)))}
  end

  @impl true
  def handle_event("validate", %{"thread" => params}, socket) do
    changeset = Thread.changeset(socket.assigns.thread, params)

    {:noreply,
     socket
     |> assign(:tags, params["tags"])
     |> assign(:form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"thread" => params}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    case Forums.update_thread(thread, Map.take(params, ["title", "tags"]), user) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> put_flash(:info, "Thread updated successfully.")
         |> push_navigate(to: ~p"/categories/#{socket.assigns.category}/threads/#{thread}")}

      {:error, changeset} ->
        {:noreply, socket |> assign(:tags, params["tags"]) |> assign(:form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Edit Thread" />

      <.form for={@form} id="thread-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input field={@form[:title]} type="text" label="Title" />
        <.tags_input field={@form[:tags]} value={@tags} />
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
