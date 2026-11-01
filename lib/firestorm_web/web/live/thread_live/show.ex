defmodule FirestormWeb.Web.ThreadLive.Show do
  @moduledoc """
  A thread and its posts. New and edited posts appear live. Viewing the thread moves the
  current user's read position to its newest post; posts that were unread when
  the page opened are marked with a "new since your last visit" divider.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.{Subscriptions, Thread}

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
  def handle_info({event, _post}, socket) when event in [:post_created, :post_updated],
    do: {:noreply, load_thread(socket, socket.assigns.thread)}

  def handle_info({:thread_updated, thread}, socket) do
    if thread.category_id == socket.assigns.category.id,
      do: {:noreply, load_thread(socket, thread)},
      else:
        {:noreply,
         push_navigate(socket, to: ~p"/categories/#{thread.category_id}/threads/#{thread}")}
  end

  def handle_info({:thread_deleted, _thread}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "This thread was deleted.")
     |> push_navigate(to: ~p"/categories/#{socket.assigns.category}")}
  end

  def handle_info({_event, _thread}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, _params, %{assigns: %{current_user: nil}} = socket)
      when event in ["set_level", "delete", "moderate", "move"] do
    {:noreply, put_flash(socket, :error, denied_message(nil))}
  end

  def handle_event("set_level", %{"level" => level}, socket)
      when level in ["watching", "tracking", "normal", "muted"] do
    {:ok, _} =
      Subscriptions.set_thread_level(socket.assigns.current_user, socket.assigns.thread, level)

    {:noreply, assign(socket, :level, level)}
  end

  def handle_event("moderate", %{"action" => action}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    if can?(user, :moderate_thread) do
      result =
        case action do
          "pin" -> Forums.pin_thread(thread, true)
          "unpin" -> Forums.pin_thread(thread, false)
          "close" -> Forums.close_thread(thread, true)
          "open" -> Forums.close_thread(thread, false)
          "archive" -> Forums.archive_thread(thread, true)
          "unarchive" -> Forums.archive_thread(thread, false)
        end

      {:ok, thread} = result
      {:noreply, socket |> put_flash(:info, moderation_message(action)) |> load_thread(thread)}
    else
      {:noreply, put_flash(socket, :error, denied_message(user))}
    end
  end

  def handle_event("move", %{"move" => %{"category_id" => category_id}}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    if can?(user, :moderate_thread) do
      category = Forums.get_category!(category_id)
      {:ok, moved} = Forums.move_thread(thread, category)

      {:noreply,
       socket
       |> put_flash(:info, "Thread moved to #{category.title}.")
       |> push_navigate(to: ~p"/categories/#{category}/threads/#{moved}")}
    else
      {:noreply, put_flash(socket, :error, denied_message(user))}
    end
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
    |> assign(:level, Subscriptions.thread_level(user, thread))
    |> assign(:inherited_level, inherited_level(user, socket.assigns.category))
    |> assign(:editable_ids, editable_ids(user, thread))
    |> assign(:can_manage?, can?(user, :update_thread, thread))
    |> assign(:can_moderate?, can?(user, :moderate_thread))
    |> assign(
      :categories,
      if(can?(user, :moderate_thread), do: Forums.list_categories(), else: [])
    )
  end

  # The posts the user may edit (roles loaded once, not per post).
  defp editable_ids(nil, _thread), do: MapSet.new()

  defp editable_ids(user, thread) do
    user = Repo.preload(user, :roles)

    for post <- thread.posts,
        can?(user, :edit_post, %{post: post, thread: thread}),
        into: MapSet.new() do
      post.id
    end
  end

  defp moderation_message("pin"), do: "Thread pinned."
  defp moderation_message("unpin"), do: "Thread unpinned."
  defp moderation_message("close"), do: "Thread closed."
  defp moderation_message("open"), do: "Thread reopened."
  defp moderation_message("archive"), do: "Thread archived."
  defp moderation_message("unarchive"), do: "Thread unarchived."

  defp inherited_level(user, category),
    do: Subscriptions.category_level(user, category) || "normal"

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
        <h1 class="flex items-center gap-2 text-2xl font-bold tracking-tight">
          <.thread_status thread={@thread} />
          <.link navigate={~p"/categories/#{@category}/threads/#{@thread}"}>{@thread.title}</.link>
        </h1>
        <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
          <.avatar user={@first_post.user} size="size-6" />
          <.link navigate={~p"/users/#{@first_post.user}"} class="font-medium hover:text-primary">
            @{@first_post.user.username}
          </.link>
          · <.time_ago id="thread-time" at={@thread.inserted_at} />
          · <span id="reply-count">{ngettext("1 reply", "%{count} replies", length(@replies))}</span>
          <span :if={@can_manage? or @can_moderate?} class="ml-auto flex gap-1">
            <div :if={@can_moderate?} id="moderation" class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-ghost btn-xs">
                <.icon name="hero-shield-check" class="size-4" /> Moderate
              </div>
              <div
                tabindex="0"
                class="dropdown-content z-10 w-64 space-y-2 rounded-box border border-base-300 bg-base-100 p-2 shadow"
              >
                <ul class="menu w-full p-0">
                  <li>
                    <button
                      phx-click="moderate"
                      phx-value-action={if @thread.pinned_at, do: "unpin", else: "pin"}
                    >
                      <.icon name="hero-bookmark" class="size-4" />
                      {if @thread.pinned_at, do: "Unpin", else: "Pin"}
                    </button>
                  </li>
                  <li>
                    <button
                      phx-click="moderate"
                      phx-value-action={if @thread.closed_at, do: "open", else: "close"}
                    >
                      <.icon name="hero-lock-closed" class="size-4" />
                      {if @thread.closed_at, do: "Reopen", else: "Close"}
                    </button>
                  </li>
                  <li>
                    <button
                      phx-click="moderate"
                      phx-value-action={if @thread.archived_at, do: "unarchive", else: "archive"}
                    >
                      <.icon name="hero-archive-box" class="size-4" />
                      {if @thread.archived_at, do: "Unarchive", else: "Archive"}
                    </button>
                  </li>
                </ul>
                <.form for={%{}} as={:move} id="move-thread-form" phx-submit="move" class="flex gap-1">
                  <select name="move[category_id]" class="select select-sm flex-1" aria-label="Move to category">
                    <option :for={c <- @categories} value={c.id} selected={c.id == @thread.category_id}>
                      {c.title}
                    </option>
                  </select>
                  <button class="btn btn-sm">Move</button>
                </.form>
              </div>
            </div>
            <.link
              :if={@can_manage?}
              navigate={~p"/categories/#{@category}/threads/#{@thread}/edit"}
              class="btn btn-ghost btn-xs"
            >
              Edit
            </.link>
            <button
              :if={@can_manage?}
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
          <.post
            post={@first_post}
            thread={@thread}
            can_edit={MapSet.member?(@editable_ids, @first_post.id)}
          >
            <:actions>
              <.level_picker
                :if={@current_user}
                id="thread-level"
                level={@level}
                inherited={@inherited_level}
              />
            </:actions>
          </.post>
        </li>
        <li :for={post <- @replies}>
          <div
            :if={post.id == first_unread_id(@replies, @last_read_post_id)}
            id="new-posts-divider"
            class="divider divider-primary text-xs text-primary"
          >
            New since your last visit
          </div>
          <.post post={post} thread={@thread} can_edit={MapSet.member?(@editable_ids, post.id)} />
        </li>
      </ol>

      <div :if={Thread.closed?(@thread)} id="closed-notice" role="status" class="alert">
        <.icon name="hero-lock-closed" class="size-5" />
        {if Thread.archived?(@thread),
          do: "This thread is archived. It's read-only.",
          else: "This thread is closed to new replies."}
      </div>
      <div :if={!Thread.closed?(@thread)} class="flex justify-end">
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
