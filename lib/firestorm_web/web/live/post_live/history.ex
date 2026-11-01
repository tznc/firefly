defmodule FirestormWeb.Web.PostLive.History do
  @moduledoc """
  A post's edit history: each edit (newest first) with who made it, when, and
  a word diff of what changed. Updates live when the post is edited again.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Post

  @impl true
  def mount(
        %{"category_id" => category_id, "thread_id" => thread_id, "id" => id},
        _session,
        socket
      ) do
    category = Forums.get_visible_category!(category_id, socket.assigns.current_user)
    thread = Forums.get_visible_thread!(category, thread_id, socket.assigns.current_user)
    post = thread |> Forums.get_post!(id) |> FirestormWeb.Repo.preload(:user)
    socket = assign(socket, category: category, thread: thread)

    # A deleted post's content (and so its history) is for admins only.
    if Post.deleted?(post) and not can?(socket.assigns.current_user, :view_deleted_posts) do
      {:ok,
       socket
       |> put_flash(:error, "This post was deleted.")
       |> push_navigate(to: ~p"/categories/#{category}/threads/#{thread}")}
    else
      if connected?(socket), do: Forums.subscribe("forums:thread:#{thread.id}")
      {:ok, socket |> assign(:page_title, "Edit history - #{thread.title}") |> load(post)}
    end
  end

  @impl true
  def handle_info({:post_updated, %{id: id} = post}, %{assigns: %{post: %{id: id}}} = socket),
    do: {:noreply, load(socket, post)}

  def handle_info(_event, socket), do: {:noreply, socket}

  defp load(socket, post), do: assign(socket, post: post, edits: Forums.post_edits(post))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Edit history">
        <:subtitle>
          Post by @{@post.user.username} in
          <.link
            navigate={~p"/categories/#{@category}/threads/#{@thread}" <> "#post-#{@post.id}"}
            class="link"
          >
            {@thread.title}
          </.link>
        </:subtitle>
      </.page_header>

      <p :if={@edits == []} class="text-base-content/60">This post hasn't been edited.</p>

      <ol id="revisions" class="space-y-4">
        <li
          :for={{edit, index} <- Enum.with_index(@edits)}
          id={"revision-#{length(@edits) - index}"}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-3 p-5">
            <header class="flex flex-wrap items-center gap-2 text-sm">
              <span class="badge badge-ghost">Edit {length(@edits) - index}</span>
              <span :if={edit.editor} class="font-semibold">@{edit.editor.username}</span>
              <span :if={!edit.editor} class="italic text-base-content/60">a deleted user</span>
              <.time_ago
                id={"revision-#{length(@edits) - index}-time"}
                at={edit.at}
                class="text-base-content/60"
              />
            </header>
            <.post_diff diff={edit.diff} />
          </div>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
