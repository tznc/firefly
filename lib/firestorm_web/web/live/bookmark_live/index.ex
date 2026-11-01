defmodule FirestormWeb.Web.BookmarkLive.Index do
  @moduledoc """
  The user's bookmarks (see `FirestormWeb.Bookmarks`), pending reminders
  first: open the post, edit the note and reminder, clear the reminder or
  delete the bookmark. Reloads when a reminder fires (it's a new
  notification).
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  import FirestormWeb.Web.BookmarkComponents

  alias FirestormWeb.Bookmarks

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Bookmarks")
     |> assign(:tz_offset, tz_offset(socket))
     |> assign(:editing, nil)
     |> load()}
  end

  @doc false
  def notifications_changed(socket), do: load(socket)

  defp load(socket), do: assign(socket, :bookmarks, Bookmarks.list(socket.assigns.current_user))

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.bookmarks, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      bookmark ->
        form = to_form(form_params(bookmark, socket.assigns.tz_offset), as: :bookmark)
        {:noreply, assign(socket, editing: bookmark.id, form: form)}
    end
  end

  def handle_event("cancel_bookmark", _params, socket),
    do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_bookmark", _params, %{assigns: %{editing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_bookmark", %{"bookmark" => params}, socket) do
    %{current_user: user, editing: id, tz_offset: offset} = socket.assigns

    case Bookmarks.update(user, id, params, offset) do
      {:ok, _bookmark} ->
        {:noreply,
         socket |> assign(:editing, nil) |> put_flash(:info, "Bookmark saved.") |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = to_form(params, as: :bookmark, errors: changeset.errors)
        {:noreply, assign(socket, :form, form)}

      {:error, reason} ->
        {:noreply,
         socket |> assign(:editing, nil) |> put_flash(:error, Bookmarks.message(reason)) |> load()}
    end
  end

  def handle_event("clear_reminder", %{"id" => id}, socket) do
    :ok = Bookmarks.clear_reminder(socket.assigns.current_user, id)
    {:noreply, socket |> put_flash(:info, "Reminder cleared.") |> load()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    :ok = Bookmarks.delete(socket.assigns.current_user, id)
    {:noreply, socket |> put_flash(:info, "Bookmark deleted.") |> load()}
  end

  defp post_path(%{thread: thread} = post),
    do: ~p"/categories/#{thread.category_id}/threads/#{thread}" <> "#post-#{post.id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Bookmarks" navigate={~p"/bookmarks"}>
        <:subtitle>Posts you bookmarked, with your notes and reminders.</:subtitle>
      </.page_header>

      <p :if={@bookmarks == []} id="no-bookmarks" class="text-base-content/70">
        No bookmarks. Use the <.icon name="hero-bookmark" class="size-4" /> button on a post to add one.
      </p>

      <ul id="bookmarks" class="space-y-2">
        <li
          :for={bookmark <- @bookmarks}
          id={"bookmark-#{bookmark.id}"}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-1 p-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="flex items-center gap-2">
                <.category_badge category={bookmark.post.thread.category} />
                <.link navigate={post_path(bookmark.post)} class="font-medium hover:text-primary">
                  {bookmark.post.thread.title}
                </.link>
              </span>
              <span class="text-sm text-base-content/60">
                @{bookmark.post.user.username} ·
                <.time_ago id={"bookmark-#{bookmark.id}-post-at"} at={bookmark.post.inserted_at} />
              </span>
            </div>
            <p :if={bookmark.note} class="bookmark-note font-medium">{bookmark.note}</p>
            <p class="line-clamp-2 text-sm text-base-content/80">{bookmark.post.body}</p>
            <p :if={bookmark.remind_at} class="bookmark-reminder text-sm text-primary">
              <.icon name="hero-bell-alert" class="size-4" /> Reminder
              <.time_ago id={"bookmark-#{bookmark.id}-remind-at"} at={bookmark.remind_at} />
            </p>
            <div class="flex flex-wrap gap-2">
              <.link navigate={post_path(bookmark.post)} class="btn btn-primary btn-sm">Open</.link>
              <button phx-click="edit" phx-value-id={bookmark.id} class="btn btn-ghost btn-sm">
                Edit
              </button>
              <button
                :if={bookmark.remind_at}
                phx-click="clear_reminder"
                phx-value-id={bookmark.id}
                class="btn btn-ghost btn-sm"
              >
                Clear reminder
              </button>
              <button
                phx-click="delete"
                phx-value-id={bookmark.id}
                data-confirm="Delete this bookmark?"
                class="btn btn-ghost btn-sm text-error"
              >
                Delete
              </button>
            </div>
            <.bookmark_form :if={@editing == bookmark.id} form={@form} />
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
