defmodule FirestormWeb.Web.ThreadLive.Show do
  @moduledoc """
  A thread and its posts. New posts appear live; viewing the thread marks its
  posts as read for the current user.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Repo}

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    category = Forums.get_category!(category_id)
    thread = Forums.get_thread!(category, id)
    if connected?(socket), do: Forums.subscribe("forums:thread:#{thread.id}")

    {:ok,
     socket
     |> assign(:category, category)
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
    {:noreply, put_flash(socket, :error, "You must be logged in to access this page.")}
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
    {:ok, _} = Forums.delete_thread(socket.assigns.thread)

    {:noreply,
     socket
     |> put_flash(:info, "Thread deleted successfully.")
     |> push_navigate(to: ~p"/categories/#{socket.assigns.category}")}
  end

  defp load_thread(socket, thread) do
    user = socket.assigns.current_user
    thread = Repo.preload(thread, [posts: [:user]], force: true)
    [first_post | replies] = Enum.map(thread.posts, &Forums.decorate_post_oembeds/1)

    if user && connected?(socket), do: Enum.each(thread.posts, &Forums.view(user, &1))

    socket
    |> assign(:page_title, "#{thread.title} - #{socket.assigns.category.title}")
    |> assign(:thread, thread)
    |> assign(:first_post, first_post)
    |> assign(:replies, replies)
    |> assign(:watched, !!user && Forums.watched_by?(thread, user))
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
          <span :if={@current_user} class="ml-auto flex gap-1">
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
