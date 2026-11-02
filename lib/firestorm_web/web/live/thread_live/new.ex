defmodule FirestormWeb.Web.ThreadLive.New do
  @moduledoc """
  Starts a new thread (title, tags and first post, optionally with a poll;
  see `FirestormWeb.Polls`) in a category. What's typed is kept as a draft
  for that category (see `FirestormWeb.Web.Drafting`, the poll excepted)
  until the thread is created.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Forums, LocalTime, Polls, Tags}
  alias FirestormWeb.Forums.{Tag, Thread}
  alias FirestormWeb.Web.{Editor, PollComponents}

  import FirestormWeb.Web.Drafting
  import FirestormWeb.Web.PollComponents, only: [poll_composer: 1]

  @impl true
  def mount(%{"category_id" => category_id}, _session, socket) do
    category = Forums.get_visible_category!(category_id, socket.assigns.current_user)

    socket = assign_draft(socket, {:new_thread, category})
    draft = socket.assigns.draft || %{title: "", tags: "", body: ""}

    {:ok,
     socket
     |> assign(:page_title, "New Thread - #{category.title}")
     |> assign(:category, category)
     |> assign_form(%{"title" => draft.title, "tags" => draft.tags, "body" => draft.body})
     |> assign(:tag_groups, Tags.picker(socket.assigns.current_user))
     |> assign(:poll_open?, false)
     |> assign(:poll_form, to_form(PollComponents.defaults(), as: :poll))
     |> assign(:tz_offset, LocalTime.offset(socket))
     |> Editor.allow_attachments(&handle_progress/3)
     |> Editor.mention_search()}
  end

  @impl true
  def handle_event("validate", %{"thread" => params} = all, socket) do
    {:noreply,
     socket
     |> assign_form(params, validate_errors(socket, params))
     |> keep_poll_params(all["poll"])
     |> save_draft(params)}
  end

  def handle_event("toggle_poll", _params, socket),
    do: {:noreply, assign(socket, :poll_open?, !socket.assigns.poll_open?)}

  def handle_event("discard_draft", _params, socket) do
    {:noreply,
     socket |> discard_draft() |> assign_form(%{"title" => "", "tags" => "", "body" => ""})}
  end

  def handle_event("pick_tag", %{"name" => name}, socket) do
    params = Map.update(socket.assigns.form.params, "tags", name, &Tag.append(&1, name))
    {:noreply, socket |> assign_form(params, socket.assigns.form.errors) |> save_draft(params)}
  end

  def handle_event("save", %{"thread" => params} = all, socket) do
    socket = keep_poll_params(socket, all["poll"])

    case FirestormWeb.Posting.check(socket.assigns.current_user) do
      :ok ->
        create_thread(socket, params)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, FirestormWeb.Posting.message(reason))}
    end
  end

  defp create_thread(socket, params) do
    attrs = %{title: params["title"], tags: params["tags"], body: params["body"]}

    case Forums.create_thread(
           socket.assigns.category,
           socket.assigns.current_user,
           with_poll(socket, attrs)
         ) do
      {:ok, thread} ->
        {:noreply,
         socket
         |> discard_draft()
         |> put_flash(
           :info,
           if(FirestormWeb.Forums.Post.queued?(thread.first_post),
             do: "Thanks! Your thread is awaiting approval by staff.",
             else: "Thread created successfully."
           )
         )
         |> push_navigate(to: ~p"/categories/#{socket.assigns.category}/threads/#{thread}")}

      {:error, changeset} ->
        poll_form =
          to_form(socket.assigns.poll_form.params,
            as: :poll,
            errors: PollComponents.errors(changeset),
            action: :validate
          )

        {:noreply,
         socket |> assign_form(params, errors(changeset)) |> assign(:poll_form, poll_form)}
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

  defp handle_progress(:attachment, entry, socket) do
    Editor.attachment_progress(socket, entry, fn socket, markdown ->
      params =
        Map.update(socket.assigns.form.params, "body", markdown, &Editor.append(&1, markdown))

      {:noreply, socket |> assign_form(params, socket.assigns.form.errors) |> save_draft(params)}
    end)
  end

  defp save_draft(socket, params),
    do: autosave(socket, %{title: params["title"], tags: params["tags"], body: params["body"]})

  defp assign_form(socket, params, errors \\ []) do
    action = if errors == [], do: nil, else: :validate
    assign(socket, :form, to_form(params, as: :thread, errors: errors, action: action))
  end

  defp validate_errors(socket, params) do
    %{
      thread: %{title: params["title"], category_id: socket.assigns.category.id},
      post: %{body: params["body"], user_id: socket.assigns.current_user.id}
    }
    |> Thread.new_changeset()
    |> errors()
  end

  # The thread changeset nests the first post's errors under :posts; flatten
  # them so the body field can show them.
  defp errors(%Ecto.Changeset{valid?: true}), do: []

  defp errors(changeset) do
    post_errors =
      case Ecto.Changeset.get_change(changeset, :posts) do
        [post_changeset | _] -> post_changeset.errors
        _ -> []
      end

    Keyword.take(changeset.errors, [:title, :tags]) ++ Keyword.take(post_errors, [:body])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Start a new thread">
        <:subtitle>
          in <.link navigate={~p"/categories/#{@category}"} class="link">{@category.title}</.link>
        </:subtitle>
      </.page_header>

      <.form for={@form} id="thread-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input field={@form[:title]} type="text" label="Title" placeholder="Type a title" phx-debounce="300" />
        <.tags_input field={@form[:tags]} />
        <.tag_picker groups={@tag_groups} />
        <Editor.body_editor
          field={@form[:body]}
          uploads={@uploads}
          user={@current_user}
          placeholder="Type thread content here. Use markdown syntax."
        />
        <.poll_composer form={@poll_form} open={@poll_open?} />
        <.draft_status draft={@draft} error={@draft_error} />
        <div class="flex justify-end gap-2">
          <.link navigate={~p"/categories/#{@category}"} class="btn btn-ghost">Cancel</.link>
          <.button variant="primary" phx-disable-with="Creating...">Create Thread</.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
