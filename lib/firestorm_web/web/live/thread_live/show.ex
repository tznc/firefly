defmodule FirestormWeb.Web.ThreadLive.Show do
  @moduledoc """
  A thread and its posts. New posts appear live. Viewing the thread moves the
  current user's read position to its newest post; posts that were unread when
  the page opened are marked with a "new since your last visit" divider.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Repo}

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    category = Forums.get_category!(category_id)
    thread = Forums.get_thread!(category, id)
    if connected?(socket), do: Forums.subscribe("forums:thread:#{thread.id}")

    # Where the user had read up to before this visit (nil: never opened).
    read = Forums.thread_read(socket.assigns.current_user, thread)

    {:ok,
     socket
     |> assign(:category, category)
     |> assign(:last_read_post_id, read && read.last_read_post_id)
     |> load_thread(thread)}
  end

  @impl true
  def handle_info({:post_created, _post}, socket),
    do: {:noreply, load_thread(socket, socket.assigns.thread)}

  def handle_info({:thread_updated, thread}, socket), do: {:noreply, load_thread(socket, thread)}

  def handle_info({:thread_deleted, _thread}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "This thread was deleted.")
     |> push_navigate(to: ~p"/categories/#{socket.assigns.category}")}
  end

  def handle_info({_event, _thread}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, _params, %{assigns: %{current_user: nil}} = socket)
      when event in ["watch", "unwatch", "delete"] do
    {:noreply, put_flash(socket, :error, denied_message(nil))}
  end

  def handle_event("watch", _params, socket) do
    Forums.watch(socket.assigns.current_user, socket.assigns.thread)
    {:noreply, assign(socket, :watched, true)}
  end

  def handle_event("unwatch", _params, socket) do
    Forums.unwatch(socket.assigns.current_user, socket.assigns.thread)
    {:noreply, assign(socket, :watched, false)}
  end

  def handle_event("delete", _params, socket) do
    if can?(socket.assigns.current_user, :delete_thread, socket.assigns.thread) do
      {:ok, _} = Forums.delete_thread(socket.assigns.thread)

      {:noreply,
       socket
       |> put_flash(:info, "Thread deleted successfully.")
       |> push_navigate(to: ~p"/categories/#{socket.assigns.category}")}
    else
      {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
    end
  end

  defp load_thread(socket, thread) do
    user = socket.assigns.current_user
    thread = Repo.preload(thread, [posts: [:user]], force: true)
    [first_post | replies] = Enum.map(thread.posts, &Forums.decorate_post_oembeds/1)

    if user && connected?(socket), do: Forums.mark_thread_read(user, thread)

    socket
    |> assign(:page_title, "#{thread.title} - #{socket.assigns.category.title}")
    |> assign(:thread, thread)
    |> assign(:first_post, first_post)
    |> assign(:replies, replies)
    |> assign(:watched, !!user && Forums.watched_by?(thread, user))
    |> assign(:can_manage?, can?(user, :update_thread, thread))
    |> assign(:first_unread_id, first_unread_id(replies, socket.assigns.last_read_post_id))
  end

  defp first_unread_id(_replies, nil), do: nil

  defp first_unread_id(replies, last_read_post_id) do
    Enum.find_value(replies, fn post -> post.id > last_read_post_id && post.id end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <header class="space-y-3">
        <.category_badge category={@category} />
        <h1 class="text-2xl font-bold tracking-tight">
          <.link navigate={~p"/categories/#{@category}/threads/#{@thread}"}>{@thread.title}</.link>
        </h1>
        <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
          <.avatar user={@first_post.user} size="size-6" />
          <.link navigate={~p"/users/#{@first_post.user}"} class="font-medium hover:text-primary">
            @{@first_post.user.username}
          </.link>
          · <.time_ago id="thread-time" at={@thread.inserted_at} />
          · <span id="reply-count">{ngettext("1 reply", "%{count} replies", length(@replies))}</span>
          <span :if={@can_manage?} class="ml-auto flex gap-1">
            <.link
              navigate={~p"/categories/#{@category}/threads/#{@thread}/edit"}
              class="btn btn-ghost btn-xs"
            >
              Edit
            </.link>
            <button
              phx-click="delete"
              data-confirm="Delete this thread?"
              class="btn btn-ghost btn-xs text-error"
            >
              Delete
            </button>
          </span>
        </div>
      </header>

      <ol id="posts" class="space-y-4">
        <li>
          <.post post={@first_post} thread={@thread}>
            <:actions>
              <button
                :if={@watched}
                id="unwatch"
                phx-click="unwatch"
                class="btn btn-ghost btn-sm btn-square text-primary"
                aria-label="unwatch"
                title="Stop watching this thread"
              >
                <.icon name="hero-eye-solid" class="size-4" />
              </button>
              <button
                :if={!@watched}
                id="watch"
                phx-click="watch"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="watch"
                title="Watch this thread"
              >
                <.icon name="hero-eye" class="size-4" />
              </button>
            </:actions>
          </.post>
        </li>
        <li :for={post <- @replies}>
          <div
            :if={post.id == @first_unread_id}
            id="new-posts-divider"
            class="divider divider-primary text-xs text-primary"
          >
            New since your last visit
          </div>
          <.post post={post} thread={@thread} />
        </li>
      </ol>

      <div class="flex justify-end">
        <.link
          navigate={~p"/categories/#{@category}/threads/#{@thread}/posts/new"}
          class="btn btn-primary"
        >
          <.icon name="hero-arrow-uturn-left" class="size-4" /> Reply
        </.link>
      </div>
    </Layouts.app>
    """
  end
end
