defmodule FirestormWeb.Web.PostLive.New do
  @moduledoc """
  Replies to a thread, optionally quoting one of its posts, optionally
  with a poll (see `FirestormWeb.Polls`). What's typed is kept as a draft
  (see `FirestormWeb.Web.Drafting`, the poll excepted) until it's posted.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Forums, LocalTime, Polls, Quote, Repo}
  alias FirestormWeb.Forums.Post
  alias FirestormWeb.Web.{Editor, PollComponents}

  import FirestormWeb.Web.Drafting
  import FirestormWeb.Web.PollComponents, only: [poll_composer: 1]

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
    socket = assign_draft(socket, {:reply, thread})
    # A quote opened over a draft is added to it.
    body =
      case {socket.assigns.draft, quote_body(category, thread, params)} do
        {nil, quoted} -> quoted
        {draft, nil} -> draft.body
        {draft, quoted} -> Editor.append(draft.body, quoted)
      end

    {:ok,
     socket
     |> assign(:page_title, "Reply - #{thread.title}")
     |> assign(:category, category)
     |> assign(:thread, thread)
     |> assign(:form, to_form(Forums.change_post(%Post{thread_id: thread.id, body: body})))
     |> assign(:poll_open?, false)
     |> assign(:poll_form, to_form(PollComponents.defaults(), as: :poll))
     |> assign(:tz_offset, LocalTime.offset(socket))
     |> Editor.allow_attachments(&handle_progress/3)
     |> Editor.mention_search()}
  end

  @impl true
  def handle_event("validate", %{"post" => params} = all, socket) do
    changeset = Post.changeset(%Post{}, post_attrs(socket, params))

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, action: :validate))
     |> keep_poll_params(all["poll"])
     |> autosave(%{body: params["body"]})}
  end

  def handle_event("toggle_poll", _params, socket),
    do: {:noreply, assign(socket, :poll_open?, !socket.assigns.poll_open?)}

  def handle_event("discard_draft", _params, socket) do
    form = to_form(Forums.change_post(%Post{thread_id: socket.assigns.thread.id}))
    {:noreply, socket |> discard_draft() |> assign(:form, form)}
  end

  def handle_event("save", %{"post" => params} = all, socket) do
    %{thread: thread, category: category, current_user: user} = socket.assigns
    socket = keep_poll_params(socket, all["poll"])

    case FirestormWeb.Posting.check(user, thread) do
      :ok ->
        create_post(socket, thread, category, user, params)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FirestormWeb.Posting.message(reason))}
    end
  end

  defp create_post(socket, thread, category, user, params) do
    case Forums.create_post(thread, user, with_poll(socket, %{body: params["body"]})) do
      {:ok, post} ->
        {:noreply,
         socket
         |> discard_draft()
         |> put_flash(:info, created_message(post))
         |> push_navigate(to: ~p"/categories/#{category}/threads/#{thread}")}

      {:error, :closed} ->
        {:noreply, put_flash(socket, :error, FirestormWeb.Posting.message(:closed))}

      {:error, changeset} ->
        poll_form =
          to_form(socket.assigns.poll_form.params,
            as: :poll,
            errors: PollComponents.errors(changeset),
            action: :validate
          )

        {:noreply, assign(socket, form: to_form(changeset), poll_form: poll_form)}
    end
  end

  defp keep_poll_params(socket, nil), do: socket

  defp keep_poll_params(socket, params),
    do: assign(socket, :poll_form, to_form(params, as: :poll))

  defp with_poll(%{assigns: %{poll_open?: true}} = socket, attrs),
    do:
      Map.put(
        attrs,
        :poll,
        Polls.attrs(socket.assigns.poll_form.params, socket.assigns.tz_offset)
      )

  defp with_poll(_socket, attrs), do: attrs

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
    Editor.attachment_progress(socket, entry, fn socket, markdown ->
      body = Editor.append(socket.assigns.form[:body].value, markdown)
      changeset = Post.changeset(%Post{}, post_attrs(socket, %{"body" => body}))
      {:noreply, socket |> assign(:form, to_form(changeset)) |> autosave(%{body: body})}
    end)
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
        <Editor.body_editor field={@form[:body]} uploads={@uploads} user={@current_user} />
        <.poll_composer form={@poll_form} open={@poll_open?} />
        <.draft_status draft={@draft} error={@draft_error} />
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
