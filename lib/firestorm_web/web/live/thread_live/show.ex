defmodule FirestormWeb.Web.ThreadLive.Show do
  @moduledoc """
  A thread and its posts. New, edited and deleted posts appear live. Members
  see a placeholder for a deleted reply; admins see it dimmed, to restore. Viewing the thread moves the
  current user's read position to its newest post; posts that were unread when
  the page opened are marked with a "new since your last visit" divider.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Mentions, Posting, RateLimit, Repo}
  alias FirestormWeb.Forums.{Category, Post, Subscriptions, Thread}

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    thread = Forums.get_thread!(id)

    # Links from before a move (notifications, emails, bookmarks) still carry
    # the old category: send them to the thread where it lives now.
    if to_string(thread.category_id) == category_id do
      mount_thread(Forums.get_category!(category_id), thread, socket)
    else
      {:ok, push_navigate(socket, to: ~p"/categories/#{thread.category_id}/threads/#{thread}")}
    end
  end

  defp mount_thread(category, thread, socket) do
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
  def handle_info({event, _post}, socket)
      when event in [
             :post_created,
             :post_updated,
             :post_deleted,
             :post_restored
           ],
      do: {:noreply, load_thread(socket, socket.assigns.thread)}

  # Likes are frequent: refresh just that post's likers, not the whole thread.
  def handle_info({:post_likes_changed, post}, socket),
    do: {:noreply, refresh_likers(socket, post)}

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
      when event in [
             "set_level",
             "delete",
             "moderate",
             "move",
             "delete_post",
             "restore_post",
             "toggle_like"
           ] do
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
      case moderate(thread, action, user) do
        {:ok, thread} ->
          {:noreply,
           socket |> put_flash(:info, moderation_message(action)) |> load_thread(thread)}

        _error ->
          {:noreply, put_flash(socket, :error, "Couldn't update the thread.")}
      end
    else
      {:noreply, put_flash(socket, :error, denied_message(user))}
    end
  end

  def handle_event("move", %{"move" => %{"category_id" => category_id}}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    with true <- can?(user, :moderate_thread) || :denied,
         %Category{} = category <- Forums.get_category(category_id) || :no_category,
         {:ok, moved} <- Forums.move_thread(thread, category, user) do
      {:noreply,
       socket
       |> put_flash(:info, "Thread moved to #{category.title}.")
       |> push_navigate(to: ~p"/categories/#{category}/threads/#{moved}")}
    else
      :denied -> {:noreply, put_flash(socket, :error, denied_message(user))}
      :no_category -> {:noreply, put_flash(socket, :error, "That category no longer exists.")}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Couldn't move the thread.")}
    end
  end

  def handle_event("delete_post", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns
    post = Forums.get_post!(thread, id)

    with true <- can?(user, :delete_post, %{post: post, thread: Forums.get_thread!(thread.id)}),
         {:ok, _} <- Forums.delete_post(post, user) do
      {:noreply, socket |> put_flash(:info, "Post deleted.") |> load_thread(thread)}
    else
      {:error, :first_post} ->
        {:noreply, put_flash(socket, :error, "Delete the thread to remove its first post.")}

      false ->
        {:noreply, put_flash(socket, :error, denied_message(user))}
    end
  end

  def handle_event("restore_post", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    if can?(user, :restore_post) do
      {:ok, _} = thread |> Forums.get_post!(id) |> Forums.restore_post(user)
      {:noreply, socket |> put_flash(:info, "Post restored.") |> load_thread(thread)}
    else
      {:noreply, put_flash(socket, :error, denied_message(user))}
    end
  end

  def handle_event("toggle_like", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns
    post = Forums.get_post!(thread, id)

    with true <- can?(user, :like_post, %{post: post, thread: Forums.get_thread!(thread.id)}),
         :ok <- Posting.check(user, :like),
         :ok <- RateLimit.check_like(user) do
      if Forums.liked?(post, user),
        do: Forums.unlike_post(post, user),
        else: Forums.like_post(post, user)

      {:noreply, refresh_likers(socket, post)}
    else
      false -> {:noreply, put_flash(socket, :error, denied_message(user))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Posting.message(reason))}
    end
  end

  def handle_event("set_level", _params, socket), do: {:noreply, socket}

  def handle_event("delete", _params, socket) do
    if can?(socket.assigns.current_user, :delete_thread, socket.assigns.thread) do
      {:ok, _} = Forums.delete_thread(socket.assigns.thread, socket.assigns.current_user)

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
    thread = Repo.preload(thread, [:tags, posts: [:user, :deleted_by]], force: true)
    [first_post | replies] = Enum.map(thread.posts, &Forums.decorate_post_oembeds/1)

    if user && connected?(socket), do: Forums.mark_thread_read(user, thread)

    socket
    |> assign(:page_title, "#{thread.title} - #{socket.assigns.category.title}")
    |> assign(:thread, thread)
    |> assign(:first_post, first_post)
    |> assign(:replies, replies)
    |> assign(:refs, Mentions.refs(Enum.map(thread.posts, & &1.body)))
    |> assign(:level, Subscriptions.thread_level(user, thread))
    |> assign(:inherited_level, Subscriptions.inherited_level(user, thread))
    |> assign(:editable_ids, permitted_ids(user, thread, :edit_post))
    |> assign(:deletable_ids, permitted_ids(user, thread, :delete_post))
    |> assign(:admin?, can?(user, :view_deleted_posts))
    |> assign(:likers, Forums.likers(thread.posts))
    |> assign(:likeable_ids, permitted_ids(user, thread, :like_post))
    |> assign(:can_manage?, can?(user, :update_thread, thread))
    |> assign(:can_moderate?, can?(user, :moderate_thread))
    |> assign(
      :categories,
      if(can?(user, :moderate_thread), do: Forums.list_categories(), else: [])
    )
    |> assign(:first_unread_id, first_unread_id(replies, socket.assigns.last_read_post_id))
  end

  defp moderate(thread, "pin", user), do: Forums.pin_thread(thread, true, user)
  defp moderate(thread, "unpin", user), do: Forums.pin_thread(thread, false, user)
  defp moderate(thread, "close", user), do: Forums.close_thread(thread, true, user)
  defp moderate(thread, "open", user), do: Forums.close_thread(thread, false, user)
  defp moderate(thread, "archive", user), do: Forums.archive_thread(thread, true, user)
  defp moderate(thread, "unarchive", user), do: Forums.archive_thread(thread, false, user)
  defp moderate(_thread, _action, _user), do: {:error, :unknown_action}

  # The posts the user may edit or delete (roles loaded once, not per post).
  defp permitted_ids(nil, _thread, _action), do: MapSet.new()

  defp permitted_ids(user, thread, action) do
    user = Repo.preload(user, :roles)

    for post <- thread.posts,
        can?(user, action, %{post: post, thread: thread}),
        into: MapSet.new() do
      post.id
    end
  end

  defp refresh_likers(socket, post) do
    likers = Map.get(Forums.likers([post]), post.id, [])
    assign(socket, :likers, Map.put(socket.assigns.likers, post.id, likers))
  end

  defp reply_count(replies), do: Enum.count(replies, &(!Post.deleted?(&1)))

  defp moderation_message("pin"), do: "Thread pinned."
  defp moderation_message("unpin"), do: "Thread unpinned."
  defp moderation_message("close"), do: "Thread closed."
  defp moderation_message("open"), do: "Thread reopened."
  defp moderation_message("archive"), do: "Thread archived."
  defp moderation_message("unarchive"), do: "Thread unarchived."

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
        <.tag_chips tags={@thread.tags} />
        <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
          <.avatar user={@first_post.user} size="size-6" />
          <.link navigate={~p"/users/#{@first_post.user}"} class="font-medium hover:text-primary">
            @{@first_post.user.username}
          </.link>
          · <.time_ago id="thread-time" at={@thread.inserted_at} />
          · <span id="reply-count">{ngettext("1 reply", "%{count} replies", reply_count(@replies))}</span>
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
            refs={@refs}
            can_edit={MapSet.member?(@editable_ids, @first_post.id)}
          >
            <:actions>
              <.like_button
                post={@first_post}
                likers={Map.get(@likers, @first_post.id, [])}
                current_user={@current_user}
                can_like={MapSet.member?(@likeable_ids, @first_post.id)}
              />
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
            :if={post.id == @first_unread_id}
            id="new-posts-divider"
            class="divider divider-primary text-xs text-primary"
          >
            New since your last visit
          </div>
          <.deleted_post :if={Post.deleted?(post) and not @admin?} post={post} />
          <.post
            :if={not Post.deleted?(post) or @admin?}
            post={post}
            thread={@thread}
            refs={@refs}
            can_edit={MapSet.member?(@editable_ids, post.id)}
          >
            <:actions>
              <.like_button
                post={post}
                likers={Map.get(@likers, post.id, [])}
                current_user={@current_user}
                can_like={MapSet.member?(@likeable_ids, post.id)}
              />
              <button
                :if={MapSet.member?(@deletable_ids, post.id)}
                phx-click="delete_post"
                phx-value-id={post.id}
                data-confirm="Delete this post?"
                class="btn btn-ghost btn-sm btn-square text-error"
                aria-label={"Delete post #{post.id}"}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
              <button
                :if={@admin? and Post.deleted?(post)}
                phx-click="restore_post"
                phx-value-id={post.id}
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-arrow-uturn-up" class="size-4" /> Restore
              </button>
            </:actions>
          </.post>
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
