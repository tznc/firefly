defmodule FirestormWeb.Web.PostLive.Edit do
  @moduledoc """
  Edits a post's body (its author while the thread is open, or an admin).
  The previous body is kept in the post's revision history.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Forums, Posting}
  alias FirestormWeb.Forums.Post
  alias FirestormWeb.Web.Editor

  @impl true
  def mount(
        %{"category_id" => category_id, "thread_id" => thread_id, "id" => id},
        _session,
        socket
      ) do
    category = Forums.get_category!(category_id)
    thread = Forums.get_thread!(category, thread_id)
    post = Forums.get_post!(thread, id)
    socket = assign(socket, category: category, thread: thread, post: post)

    if can_edit?(socket),
      do: mount_form(socket),
      else: {:ok, socket |> deny() |> push_navigate(to: thread_path(socket))}
  end

  defp mount_form(socket) do
    {:ok,
     socket
     |> assign(:page_title, "Edit post - #{socket.assigns.thread.title}")
     |> assign(:form, to_form(Post.edit_changeset(socket.assigns.post, %{})))
     |> Editor.allow_attachments(&handle_progress/3)}
  end

  @impl true
  def handle_event("validate", %{"post" => params}, socket) do
    changeset = Post.edit_changeset(socket.assigns.post, %{body: params["body"]})
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"post" => params}, socket) do
    user = socket.assigns.current_user
    # The thread may have closed since the page opened.
    thread = Forums.get_thread!(socket.assigns.thread.id)
    socket = assign(socket, :thread, thread)

    with {:can_edit, true} <- {:can_edit, can_edit?(socket)},
         :ok <- Posting.check(user) do
      save(socket, user, params)
    else
      {:can_edit, false} -> {:noreply, deny(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Posting.message(reason))}
    end
  end

  defp save(socket, user, params) do
    case Forums.update_post(socket.assigns.post, user, %{body: params["body"]}) do
      {:ok, post} ->
        {:noreply,
         socket
         |> put_flash(:info, "Post updated successfully.")
         |> push_navigate(to: thread_path(socket) <> "#post-#{post.id}")}

      {:error, :deleted} ->
        {:noreply,
         socket
         |> put_flash(:error, "This post was deleted.")
         |> push_navigate(to: thread_path(socket))}

      {:error, :edited_elsewhere} ->
        # Keep what they typed; saving again replaces the other edit knowingly.
        post = Forums.get_post!(socket.assigns.thread, socket.assigns.post.id)

        {:noreply,
         socket
         |> assign(:post, post)
         |> assign(:form, to_form(Post.edit_changeset(post, %{body: params["body"]})))
         |> put_flash(
           :error,
           "This post was edited by someone else while you were editing. " <>
             "Check the post's history, then save again to replace their edit."
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp handle_progress(:attachment, entry, socket) do
    if entry.done? do
      markdown = Editor.consume_attachment(socket, entry)
      body = Editor.append(socket.assigns.form[:body].value, markdown)
      changeset = Post.edit_changeset(socket.assigns.post, %{body: body})
      {:noreply, assign(socket, :form, to_form(changeset))}
    else
      {:noreply, socket}
    end
  end

  defp can_edit?(%{assigns: %{current_user: user, post: post, thread: thread}}),
    do: can?(user, :edit_post, %{post: post, thread: thread})

  defp deny(socket), do: put_flash(socket, :error, denied_message(socket.assigns.current_user))

  defp thread_path(%{assigns: %{category: category, thread: thread}}),
    do: ~p"/categories/#{category}/threads/#{thread}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Edit Post">
        <:subtitle>
          In <.link navigate={~p"/categories/#{@category}/threads/#{@thread}"} class="link">
            {@thread.title}
          </.link>
        </:subtitle>
      </.page_header>

      <.form for={@form} id="post-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <Editor.body_editor field={@form[:body]} uploads={@uploads} />
        <div class="flex justify-end gap-2">
          <.link
            navigate={~p"/categories/#{@category}/threads/#{@thread}" <> "#post-#{@post.id}"}
            class="btn btn-ghost"
          >
            Cancel
          </.link>
          <.button variant="primary" phx-disable-with="Saving...">Save edit</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
