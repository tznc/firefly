defmodule FirestormWeb.Web.PostLive.New do
  @moduledoc "Replies to a thread, optionally quoting one of its posts."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Forums, Quote, Repo}
  alias FirestormWeb.Forums.Post
  alias FirestormWeb.Web.Editor

  @impl true
  def mount(%{"category_id" => category_id, "thread_id" => thread_id} = params, _session, socket) do
    category = Forums.get_visible_category!(category_id, socket.assigns.current_user)
    thread = Forums.get_visible_thread!(category, thread_id, socket.assigns.current_user)

    # A merged thread takes no replies: they go where its posts went.
    case thread.merged_into_id && Forums.get_thread_after_merges(thread.merged_into_id) do
      nil ->
        mount_reply(category, thread, params, socket)

      target ->
        {:ok,
         push_navigate(socket,
           to: ~p"/categories/#{target.category_id}/threads/#{target}/posts/new"
         )}
    end
  end

  defp mount_reply(category, thread, params, socket) do
    body = quote_body(category, thread, params)

    {:ok,
     socket
     |> assign(:page_title, "Reply - #{thread.title}")
     |> assign(:category, category)
     |> assign(:thread, thread)
     |> assign(:form, to_form(Forums.change_post(%Post{thread_id: thread.id, body: body})))
     |> Editor.allow_attachments(&handle_progress/3)
     |> Editor.mention_search()}
  end

  @impl true
  def handle_event("validate", %{"post" => params}, socket) do
    changeset = Post.changeset(%Post{}, post_attrs(socket, params))
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"post" => params}, socket) do
    %{thread: thread, category: category, current_user: user} = socket.assigns

    case FirestormWeb.Posting.check(user, thread) do
      :ok ->
        create_post(socket, thread, category, user, params)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FirestormWeb.Posting.message(reason))}
    end
  end

  defp create_post(socket, thread, category, user, params) do
    case Forums.create_post(thread, user, %{body: params["body"]}) do
      {:ok, post} ->
        {:noreply,
         socket
         |> put_flash(:info, created_message(post))
         |> push_navigate(to: ~p"/categories/#{category}/threads/#{thread}")}

      {:error, :closed} ->
        {:noreply, put_flash(socket, :error, FirestormWeb.Posting.message(:closed))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp created_message(%Post{queued_at: nil}), do: "Post created successfully."
  defp created_message(_queued), do: "Thanks! Your post is awaiting approval by staff."

  # `?quote=<post id>` starts the reply with a quote of that post (of just
  # `&selection=` if it's really part of the post).
  defp quote_body(category, thread, %{"quote" => post_id} = params) do
    with {id, ""} <- Integer.parse(post_id),
         %Post{} = post <- Forums.get_post(thread, id),
         # Quotes publish what they copy: only from posts anyone can read.
         true <- Post.readable_by?(post, nil) do
      post = Repo.preload(post, :user)
      url = ~p"/categories/#{category}/threads/#{thread}" <> "#post-#{post.id}"
      Quote.build(post.body, post.user.username, url, params["selection"])
    else
      _ -> nil
    end
  end

  defp quote_body(_category, _thread, _params), do: nil

  defp handle_progress(:attachment, entry, socket) do
    if entry.done? do
      markdown = Editor.consume_attachment(socket, entry)
      body = Editor.append(socket.assigns.form[:body].value, markdown)
      changeset = Post.changeset(%Post{}, post_attrs(socket, %{"body" => body}))
      {:noreply, assign(socket, :form, to_form(changeset))}
    else
      {:noreply, socket}
    end
  end

  defp post_attrs(socket, params) do
    %{
      body: params["body"],
      thread_id: socket.assigns.thread.id,
      user_id: socket.assigns.current_user.id
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="New Post">
        <:subtitle>
          Replying to
          <.link navigate={~p"/categories/#{@category}/threads/#{@thread}"} class="link">
            {@thread.title}
          </.link>
        </:subtitle>
      </.page_header>

      <.form for={@form} id="post-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <Editor.body_editor field={@form[:body]} uploads={@uploads} />
        <div class="flex justify-end gap-2">
          <.link navigate={~p"/categories/#{@category}/threads/#{@thread}"} class="btn btn-ghost">
            Cancel
          </.link>
          <.button variant="primary" phx-disable-with="Posting...">
            <.icon name="hero-arrow-uturn-left" class="size-4" /> Reply
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
