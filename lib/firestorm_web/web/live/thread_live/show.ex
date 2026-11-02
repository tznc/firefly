defmodule FirestormWeb.Web.ThreadLive.Show do
  @moduledoc """
  A thread and its posts. New, edited and deleted posts appear live. Members
  see a placeholder for a deleted reply; admins see it dimmed, to restore. Viewing the thread moves the
  current user's read position to its newest post; posts that were unread when
  the page opened are marked with a "new since your last visit" divider.

  Members can flag other people's posts (see `FirestormWeb.Flags`). A post
  hidden after flags shows as a placeholder, except to its author and
  admins, who see it with a notice; admins also see pending flag counts.
  Posts awaiting approval (see `FirestormWeb.Review`) are only shown to
  their author and admins, marked as such.

  A thread merged into another (see `FirestormWeb.TopicTools`) redirects
  there. A pending timer and slow mode (see `FirestormWeb.TopicTimers`)
  are shown above the reply button; admins manage them, and merge and
  split, from the thread's tools page (`ThreadLive.Tools`).

  Members can bookmark posts (see `FirestormWeb.Bookmarks`): bookmarking
  one opens a form for an optional note and reminder.

  In a Q&A category the thread's author and staff can accept a reply as
  the answer (see `FirestormWeb.Solved`); it's shown under the first post.

  Posts' polls (see `FirestormWeb.Polls`) take votes here, and their
  results update live.

  Admins make posts wikis (or not); members may then edit them (see the
  `:edit_post` policy).
  """
  use FirestormWeb.Web, :live_view

  import FirestormWeb.Web.BookmarkComponents
  import FirestormWeb.Web.PollComponents, only: [poll: 1]

  alias FirestormWeb.{Bookmarks, Flags, Forums, Mentions, Polls, Posting, RateLimit, Repo, Solved}
  alias FirestormWeb.TopicTimers
  alias FirestormWeb.Forums.{Category, Flag, Post, Subscriptions, Thread, ThreadTimer}

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    viewer = socket.assigns.current_user
    thread = Forums.get_thread!(id)
    # Raises (404) unless the viewer may read the thread where it is now.
    category = Forums.get_visible_category!(thread.category_id, viewer)
    thread = Forums.get_visible_thread!(category, id, viewer)

    # Links from before a move (notifications, emails, bookmarks) still carry
    # the old category, and those to a merged thread its old id: send them to
    # the thread where it lives now.
    cond do
      Thread.merged?(thread) -> {:ok, push_navigate(socket, to: merged_path(thread))}
      to_string(thread.category_id) == category_id -> mount_thread(category, thread, socket)
      true -> {:ok, push_navigate(socket, to: thread_path(thread))}
    end
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  # Where a merged thread's posts went (that thread's page checks access).
  defp merged_path(thread) do
    case Forums.get_thread_after_merges(thread.merged_into_id) do
      nil -> ~p"/"
      target -> thread_path(target)
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
     |> assign(:tz_offset, FirestormWeb.LocalTime.offset(socket))
     |> assign(:bookmarking, nil)
     |> load_thread(thread)}
  end

  @impl true
  # Access is checked again before showing anything new: the thread may have
  # been moved, or its category restricted, since the page opened.
  def handle_info({event, _post}, socket)
      when event in [
             :post_created,
             :post_updated,
             :post_deleted,
             :post_restored
           ] do
    # Read again: a post's change can change the thread (e.g. a deleted
    # answer is unaccepted).
    case Forums.get_thread(socket.assigns.thread.id) do
      nil ->
        {:noreply, leave(socket)}

      thread ->
        if can?(socket.assigns.current_user, :view_thread, thread),
          do: {:noreply, load_thread(socket, thread)},
          else: {:noreply, leave(socket)}
    end
  end

  # Likes are frequent: refresh just that post's likers, not the whole thread.
  def handle_info({:post_likes_changed, post}, socket) do
    if can?(socket.assigns.current_user, :view_thread, socket.assigns.thread),
      do: {:noreply, refresh_likers(socket, post)},
      else: {:noreply, leave(socket)}
  end

  # A vote or close: refresh just that poll.
  def handle_info({:poll_updated, post_id}, socket) do
    %{current_user: user, thread: thread, polls: polls} = socket.assigns

    cond do
      not can?(user, :view_thread, thread) ->
        {:noreply, leave(socket)}

      Map.has_key?(polls, post_id) ->
        view = Polls.view_for(%Post{id: post_id}, user)
        {:noreply, assign(socket, :polls, Map.put(polls, post_id, view))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:thread_updated, thread}, socket) do
    cond do
      Thread.merged?(thread) ->
        {:noreply,
         socket
         |> put_flash(:info, "This thread was merged into another one.")
         |> push_navigate(to: merged_path(thread))}

      not can?(socket.assigns.current_user, :view_thread, thread) ->
        {:noreply, leave(socket)}

      thread.category_id == socket.assigns.category.id ->
        {:noreply, load_thread(socket, thread)}

      true ->
        {:noreply, push_navigate(socket, to: thread_path(thread))}
    end
  end

  def handle_info({:thread_deleted, _thread}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "This thread was deleted.")
     |> push_navigate(to: ~p"/categories/#{socket.assigns.category}")}
  end

  def handle_info({_event, _thread}, socket), do: {:noreply, socket}

  defp leave(socket) do
    socket
    |> put_flash(:error, "This thread is no longer available.")
    |> push_navigate(to: ~p"/")
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{current_user: nil}} = socket)
      when event in [
             "set_level",
             "delete",
             "moderate",
             "move",
             "delete_post",
             "restore_post",
             "toggle_like",
             "flag",
             "submit_flag",
             "unhide",
             "toggle_bookmark",
             "save_bookmark",
             "accept_answer",
             "unaccept_answer",
             "vote",
             "close_poll",
             "reopen_poll",
             "toggle_wiki"
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

  def handle_event("flag", %{"id" => id}, socket) do
    post = Forums.get_post!(socket.assigns.thread, id)

    if can?(socket.assigns.current_user, :flag_post, %{post: post, thread: socket.assigns.thread}),
       do: {:noreply, assign(socket, flagging: post.id, flag_form: flag_form())},
       else: {:noreply, put_flash(socket, :error, Flags.message(:unauthorized))}
  end

  def handle_event("cancel_flag", _params, socket),
    do: {:noreply, assign(socket, :flagging, nil)}

  # Only after a "flag" event picked the post (a stale or crafted submit
  # without one is ignored).
  def handle_event("submit_flag", _params, %{assigns: %{flagging: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("submit_flag", %{"flag" => params}, socket) do
    %{thread: thread, current_user: user, flagging: post_id} = socket.assigns
    post = Forums.get_post!(thread, post_id)

    case Flags.flag_post(post, user, params) do
      {:ok, _flag} ->
        {:noreply,
         socket
         |> assign(:flagging, nil)
         |> put_flash(:info, "Thanks: staff will take a look.")
         |> load_thread(thread)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :flag_form, to_form(changeset, action: :validate))}

      {:error, reason} ->
        {:noreply, socket |> assign(:flagging, nil) |> put_flash(:error, Flags.message(reason))}
    end
  end

  def handle_event("unhide", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    with true <- can?(user, :unhide_post) || {:error, :unauthorized},
         {:ok, _post} <- thread |> Forums.get_post!(id) |> Flags.unhide(user) do
      {:noreply, socket |> put_flash(:info, "Post unhidden.") |> load_thread(thread)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Flags.message(reason))}
    end
  end

  def handle_event("accept_answer", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns
    post = Forums.get_post!(thread, id)

    case Solved.accept(thread, post, user) do
      {:ok, thread} ->
        {:noreply, socket |> put_flash(:info, "Answer accepted.") |> load_thread(thread)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Solved.message(reason))}
    end
  end

  def handle_event("unaccept_answer", _params, socket) do
    case Solved.unaccept(socket.assigns.thread, socket.assigns.current_user) do
      {:ok, thread} ->
        {:noreply, socket |> put_flash(:info, "Answer unaccepted.") |> load_thread(thread)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Solved.message(reason))}
    end
  end

  def handle_event("vote", %{"vote" => %{"poll_id" => poll_id} = params}, socket) do
    with {:ok, post_id, view} <- find_poll(socket, poll_id),
         {:ok, view} <- Polls.vote(view.poll, socket.assigns.current_user, params) do
      {:noreply,
       socket
       |> put_flash(:info, "Vote saved.")
       |> assign(:polls, Map.put(socket.assigns.polls, post_id, view))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Polls.message(reason))}
    end
  end

  def handle_event(event, %{"id" => poll_id}, socket)
      when event in ["close_poll", "reopen_poll"] do
    user = socket.assigns.current_user

    with {:ok, post_id, view} <- find_poll(socket, poll_id),
         {:ok, _poll} <-
           if(event == "close_poll",
             do: Polls.close(view.poll, user),
             else: Polls.reopen(view.poll, user)
           ) do
      view = Polls.view_for(%Post{id: post_id}, user)

      {:noreply,
       socket
       |> put_flash(:info, if(event == "close_poll", do: "Poll closed.", else: "Poll reopened."))
       |> assign(:polls, Map.put(socket.assigns.polls, post_id, view))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Polls.message(reason))}
    end
  end

  def handle_event("toggle_wiki", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns
    post = Forums.get_post!(thread, id)

    if can?(user, :toggle_wiki) do
      {:ok, post} = Forums.set_wiki(post, !Post.wiki?(post), user)
      message = if Post.wiki?(post), do: "Post is now a wiki.", else: "Post is no longer a wiki."
      {:noreply, socket |> put_flash(:info, message) |> load_thread(thread)}
    else
      {:noreply, put_flash(socket, :error, denied_message(user))}
    end
  end

  def handle_event("toggle_bookmark", %{"id" => id}, socket) do
    %{thread: thread, current_user: user} = socket.assigns
    post = Forums.get_post!(thread, id)

    if bookmark = Bookmarks.get_for_post(user, post) do
      :ok = Bookmarks.delete(user, bookmark.id)
      {:noreply, socket |> assign(:bookmarking, nil) |> assign_bookmarks()}
    else
      case Bookmarks.bookmark(user, post) do
        {:ok, bookmark} ->
          form = to_form(form_params(bookmark, socket.assigns.tz_offset), as: :bookmark)

          {:noreply,
           socket
           |> assign(bookmarking: post.id, bookmark_id: bookmark.id, bookmark_form: form)
           |> assign_bookmarks()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, Bookmarks.message(reason))}
      end
    end
  end

  def handle_event("cancel_bookmark", _params, socket),
    do: {:noreply, assign(socket, :bookmarking, nil)}

  # Only after "toggle_bookmark" opened the form.
  def handle_event("save_bookmark", _params, %{assigns: %{bookmarking: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_bookmark", %{"bookmark" => params}, socket) do
    %{current_user: user, bookmark_id: id, tz_offset: offset} = socket.assigns

    case Bookmarks.update(user, id, params, offset) do
      {:ok, _bookmark} ->
        {:noreply, socket |> assign(:bookmarking, nil) |> put_flash(:info, "Bookmark saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = to_form(params, as: :bookmark, errors: changeset.errors)
        {:noreply, assign(socket, :bookmark_form, form)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:bookmarking, nil)
         |> put_flash(:error, Bookmarks.message(reason))
         |> assign_bookmarks()}
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
    # Replies awaiting approval are only for their author and admins.
    replies = Enum.reject(replies, &(Post.queued?(&1) and not can?(user, :view_hidden_post, &1)))

    if user && connected?(socket), do: Forums.mark_thread_read(user, thread)

    socket
    |> assign(:page_title, "#{thread.title} - #{socket.assigns.category.title}")
    |> assign(:thread, thread)
    |> assign(:first_post, first_post)
    |> assign(:replies, replies)
    |> assign(:refs, Mentions.refs(Enum.map(thread.posts, & &1.body), user))
    |> assign(:level, Subscriptions.thread_level(user, thread))
    |> assign(:inherited_level, Subscriptions.inherited_level(user, thread))
    |> assign(:editable_ids, permitted_ids(user, thread, :edit_post))
    |> assign(:deletable_ids, permitted_ids(user, thread, :delete_post))
    |> assign(:admin?, can?(user, :view_deleted_posts))
    |> assign(:likers, Forums.likers(thread.posts))
    |> assign(:likeable_ids, permitted_ids(user, thread, :like_post))
    |> assign(:flaggable_ids, permitted_ids(user, thread, :flag_post))
    |> assign(:flagged_ids, Flags.flagged_ids(thread.posts, user))
    |> assign(
      :flag_counts,
      if(can?(user, :view_flags), do: Flags.pending_counts(thread.posts), else: %{})
    )
    |> assign(:hidden_ids, hidden_ids(user, thread.posts))
    |> assign(:polls, Polls.views(thread.posts, user))
    |> assign(:votable_ids, permitted_ids(user, thread, :vote_poll))
    |> assign(:poll_manageable_ids, permitted_ids(user, thread, :manage_poll))
    |> assign_bookmarks()
    |> assign_new(:flagging, fn -> nil end)
    |> assign_new(:flag_form, &flag_form/0)
    |> assign(:accepted, Enum.find(replies, &(&1.id == thread.accepted_post_id)))
    |> assign(:can_accept?, can?(user, :accept_answer, thread))
    |> assign(:can_manage?, can?(user, :update_thread, thread))
    |> assign(:can_moderate?, can?(user, :moderate_thread))
    |> assign(
      :categories,
      if(can?(user, :moderate_thread), do: Forums.list_categories(user), else: [])
    )
    |> assign(:first_unread_id, first_unread_id(replies, socket.assigns.last_read_post_id))
    |> assign(:timer, TopicTimers.get_timer(thread))
    |> assign(:slow_mode_wait, slow_mode_wait(user, thread))
  end

  # A poll on this page, by id.
  defp find_poll(socket, poll_id) do
    Enum.find_value(socket.assigns.polls, {:error, :not_found}, fn {post_id, view} ->
      to_string(view.poll.id) == to_string(poll_id) && {:ok, post_id, view}
    end)
  end

  defp assign_bookmarks(socket) do
    %{current_user: user, thread: thread} = socket.assigns
    assign(socket, :bookmarked_ids, Bookmarks.bookmarked_ids(user, thread.posts))
  end

  defp slow_mode_wait(nil, _thread), do: 0
  defp slow_mode_wait(user, thread), do: Posting.slow_mode_wait(user, thread.id)

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

  # Hidden posts the user sees only as a placeholder.
  defp hidden_ids(user, posts) do
    for post <- posts,
        Post.hidden?(post),
        not can?(user, :view_hidden_post, post),
        into: MapSet.new(),
        do: post.id
  end

  defp flag_form, do: to_form(Flag.changeset(%Flag{}, %{}))

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
          <span :if={Thread.solved?(@thread)} class="solved-badge badge badge-success">
            <.icon name="hero-check-circle" class="size-4" /> Solved
          </span>
        </h1>
        <.tag_chips tags={@thread.tags} />
        <FirestormWeb.Web.PluginComponents.plugin_outlet
          outlet="thread_header"
          key={@thread.id}
          context={%{thread_id: @thread.id}}
          user={@current_user}
          thread={@thread}
        />
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
                <.link
                  navigate={~p"/categories/#{@category}/threads/#{@thread}/tools"}
                  class="btn btn-ghost btn-sm w-full justify-start"
                >
                  <.icon name="hero-wrench-screwdriver" class="size-4" /> Merge, split, timer…
                </.link>
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
          <.hidden_post :if={MapSet.member?(@hidden_ids, @first_post.id)} post={@first_post} />
          <.hidden_notice
            :if={Post.hidden?(@first_post) and not MapSet.member?(@hidden_ids, @first_post.id)}
            post={@first_post}
            can_unhide={@admin?}
          />
          <.awaiting_notice :if={Post.queued?(@first_post)} />
          <.post
            :if={not MapSet.member?(@hidden_ids, @first_post.id)}
            post={@first_post}
            thread={@thread}
            viewer={@current_user}
            refs={@refs}
            can_edit={MapSet.member?(@editable_ids, @first_post.id)}
          >
            <:poll :if={@polls[@first_post.id]}>
              <.poll
                view={@polls[@first_post.id]}
                can_vote={MapSet.member?(@votable_ids, @first_post.id)}
                can_manage={MapSet.member?(@poll_manageable_ids, @first_post.id)}
              />
            </:poll>
            <:actions>
              <.like_button
                post={@first_post}
                likers={Map.get(@likers, @first_post.id, [])}
                current_user={@current_user}
                can_like={MapSet.member?(@likeable_ids, @first_post.id)}
              />
              <.flag_button
                post={@first_post}
                can_flag={MapSet.member?(@flaggable_ids, @first_post.id)}
                flagged={MapSet.member?(@flagged_ids, @first_post.id)}
                count={@flag_counts[@first_post.id]}
              />
              <.wiki_button :if={@admin?} post={@first_post} />
              <.bookmark_button
                :if={@current_user}
                post={@first_post}
                bookmarked={MapSet.member?(@bookmarked_ids, @first_post.id)}
              />
              <.level_picker
                :if={@current_user}
                id="thread-level"
                level={@level}
                inherited={@inherited_level}
              />
            </:actions>
          </.post>
          <.flag_reason_form :if={@flagging == @first_post.id} form={@flag_form} />
          <.bookmark_form :if={@bookmarking == @first_post.id} form={@bookmark_form} />
          <.accepted_answer :if={@accepted} post={@accepted} />
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
          <.hidden_post
            :if={not Post.deleted?(post) and MapSet.member?(@hidden_ids, post.id)}
            post={post}
          />
          <.hidden_notice
            :if={Post.hidden?(post) and not MapSet.member?(@hidden_ids, post.id)}
            post={post}
            can_unhide={@admin?}
          />
          <.awaiting_notice :if={Post.queued?(post) and not Post.deleted?(post)} />
          <.post
            :if={
              (not Post.deleted?(post) or @admin?) and not MapSet.member?(@hidden_ids, post.id)
            }
            post={post}
            thread={@thread}
            viewer={@current_user}
            refs={@refs}
            can_edit={MapSet.member?(@editable_ids, post.id)}
            accepted={post.id == @thread.accepted_post_id}
          >
            <:poll :if={@polls[post.id]}>
              <.poll
                view={@polls[post.id]}
                can_vote={MapSet.member?(@votable_ids, post.id)}
                can_manage={MapSet.member?(@poll_manageable_ids, post.id)}
              />
            </:poll>
            <:actions>
              <.like_button
                post={post}
                likers={Map.get(@likers, post.id, [])}
                current_user={@current_user}
                can_like={MapSet.member?(@likeable_ids, post.id)}
              />
              <.flag_button
                post={post}
                can_flag={MapSet.member?(@flaggable_ids, post.id)}
                flagged={MapSet.member?(@flagged_ids, post.id)}
                count={@flag_counts[post.id]}
              />
              <.accept_button
                :if={@can_accept? and Solved.acceptable?(post, @first_post)}
                post={post}
                accepted={post.id == @thread.accepted_post_id}
              />
              <.wiki_button :if={@admin? and not Post.deleted?(post)} post={post} />
              <.bookmark_button
                :if={@current_user}
                post={post}
                bookmarked={MapSet.member?(@bookmarked_ids, post.id)}
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
          <.flag_reason_form :if={@flagging == post.id} form={@flag_form} />
          <.bookmark_form :if={@bookmarking == post.id} form={@bookmark_form} />
        </li>
      </ol>

      <div :if={@timer} id="thread-timer" role="status" class="alert alert-info">
        <.icon name="hero-clock" class="size-5" />
        <span>
          {ThreadTimer.label(@timer)} <.time_ago id="thread-timer-at" at={@timer.run_at} />.
        </span>
      </div>
      <div
        :if={@thread.slow_mode_seconds && !Thread.closed?(@thread)}
        id="slow-mode-notice"
        role="status"
        class="alert"
      >
        <.icon name="hero-clock" class="size-5" />
        <span>
          Slow mode: one reply every {Posting.duration_text(@thread.slow_mode_seconds)} per member.
          <span :if={@slow_mode_wait > 0}>
            You can reply again in {Posting.duration_text(@slow_mode_wait)}.
          </span>
        </span>
      </div>
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

  attr :post, :any, required: true
  attr :can_flag, :boolean, required: true
  attr :flagged, :boolean, required: true
  attr :count, :integer, default: nil, doc: "pending flags (staff only)"

  defp flag_button(assigns) do
    ~H"""
    <span :if={@count} class="flag-count badge badge-warning badge-sm" title="Pending flags">
      <.icon name="hero-flag" class="size-3" /> {@count}
    </span>
    <span :if={@flagged} class="flagged btn btn-ghost btn-sm btn-disabled" aria-label="You flagged this post">
      <.icon name="hero-flag-solid" class="size-4" /> Flagged
    </span>
    <button
      :if={@can_flag and not @flagged}
      phx-click="flag"
      phx-value-id={@post.id}
      class="btn btn-ghost btn-sm btn-square"
      aria-label={"Flag post #{@post.id}"}
      title="Flag this post for staff"
    >
      <.icon name="hero-flag" class="size-4" />
    </button>
    """
  end

  attr :post, :any, required: true

  defp wiki_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_wiki"
      phx-value-id={@post.id}
      class={["btn btn-ghost btn-sm btn-square", @post.wiki && "text-info"]}
      aria-label={if @post.wiki, do: "Make post #{@post.id} a normal post", else: "Make post #{@post.id} a wiki"}
      title={if @post.wiki, do: "Remove wiki", else: "Make wiki"}
    >
      <.icon name="hero-pencil-square" class="size-4" />
    </button>
    """
  end

  attr :post, :any, required: true
  attr :accepted, :boolean, required: true

  defp accept_button(assigns) do
    ~H"""
    <button
      :if={@accepted}
      phx-click="unaccept_answer"
      class="btn btn-ghost btn-sm text-success"
      aria-label={"Unaccept post #{@post.id} as the answer"}
      title="Unaccept as the answer"
    >
      <.icon name="hero-check-circle-solid" class="size-4" /> Unaccept
    </button>
    <button
      :if={!@accepted}
      phx-click="accept_answer"
      phx-value-id={@post.id}
      class="btn btn-ghost btn-sm"
      aria-label={"Accept post #{@post.id} as the answer"}
      title="Accept as the answer"
    >
      <.icon name="hero-check-circle" class="size-4" /> Accept answer
    </button>
    """
  end

  attr :post, :any, required: true

  defp accepted_answer(assigns) do
    ~H"""
    <div id="accepted-answer" class="mt-2 rounded-box border border-success/50 bg-success/5 p-4 text-sm">
      <div class="flex flex-wrap items-center gap-2 font-semibold text-success">
        <.icon name="hero-check-circle-solid" class="size-5" /> Solved: accepted answer by
        <.link navigate={~p"/users/#{@post.user}"} class="link-hover">@{@post.user.username}</.link>
        <.link href={"#post-#{@post.id}"} class="btn btn-ghost btn-xs ml-auto">
          Jump to answer <.icon name="hero-arrow-down" class="size-3" />
        </.link>
      </div>
      <p class="mt-1 line-clamp-3 text-base-content/80">{String.slice(@post.body, 0, 300)}</p>
    </div>
    """
  end

  attr :form, :any, required: true

  defp flag_reason_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="flag-form"
      phx-submit="submit_flag"
      class="mt-2 space-y-2 rounded-box border border-warning/50 bg-base-100 p-4"
    >
      <p class="font-semibold">Why should staff look at this post?</p>
      <label :for={reason <- Flag.reasons()} class="flex items-center gap-2 text-sm">
        <input
          type="radio"
          name={@form[:reason].name}
          value={reason}
          checked={@form[:reason].value == reason}
          class="radio radio-sm"
        />
        {Flag.reason_label(reason)}
      </label>
      <.input field={@form[:note]} type="textarea" label="Details (required for something else)" rows="2" />
      <p :for={{message, _} <- @form[:reason].errors} class="text-sm text-error">Reason {message}</p>
      <div class="flex justify-end gap-2">
        <button type="button" phx-click="cancel_flag" class="btn btn-ghost btn-sm">Cancel</button>
        <.button variant="primary" class="btn-sm">Flag post</.button>
      </div>
    </.form>
    """
  end

  defp awaiting_notice(assigns) do
    ~H"""
    <div role="status" class="awaiting-approval alert alert-info mb-2 py-2 text-sm">
      <.icon name="hero-clock" class="size-4" />
      Awaiting approval: staff review new members' first posts. Only you and staff can see it until then.
    </div>
    """
  end
end
