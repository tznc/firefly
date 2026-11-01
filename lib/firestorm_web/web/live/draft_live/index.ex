defmodule FirestormWeb.Web.DraftLive.Index do
  @moduledoc """
  The user's drafts (see `FirestormWeb.Drafts`), most recently saved first:
  resume one in its composer, or delete it.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Drafts
  alias FirestormWeb.Forums.Draft

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Drafts") |> load()}
  end

  defp load(socket), do: assign(socket, :drafts, Drafts.list(socket.assigns.current_user))

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    :ok = Drafts.delete(socket.assigns.current_user, id)
    {:noreply, socket |> put_flash(:info, "Draft deleted.") |> load()}
  end

  defp resume_path(%Draft{kind: "new_thread", category: category}),
    do: ~p"/categories/#{category}/threads/new"

  defp resume_path(%Draft{kind: "reply", thread: thread}),
    do: ~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new"

  defp resume_path(%Draft{kind: "edit", post: post}),
    do: ~p"/categories/#{post.thread.category_id}/threads/#{post.thread}/posts/#{post}/edit"

  defp describe(%Draft{kind: "new_thread", category: category, title: title})
       when title in [nil, ""],
       do: "New thread in #{category.title}"

  defp describe(%Draft{kind: "new_thread", category: category, title: title}),
    do: "New thread in #{category.title}: #{title}"

  defp describe(%Draft{kind: "reply", thread: thread}), do: "Reply to #{thread.title}"
  defp describe(%Draft{kind: "edit", post: post}), do: "Edit of your post in #{post.thread.title}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Drafts" navigate={~p"/drafts"}>
        <:subtitle>
          Saved as you type, kept until you post or discard them (at most {Drafts.max_drafts()}).
        </:subtitle>
      </.page_header>

      <p :if={@drafts == []} id="no-drafts" class="text-base-content/70">No drafts.</p>

      <ul id="drafts" class="space-y-2">
        <li
          :for={draft <- @drafts}
          id={"draft-#{draft.id}"}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-1 p-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="font-medium">{describe(draft)}</span>
              <span class="text-sm text-base-content/60">
                <.time_ago id={"draft-#{draft.id}-at"} at={draft.updated_at} />
              </span>
            </div>
            <p class="line-clamp-2 text-sm text-base-content/80">{draft.body}</p>
            <div class="flex gap-2">
              <.link navigate={resume_path(draft)} class="btn btn-primary btn-sm">Resume</.link>
              <button
                phx-click="delete"
                phx-value-id={draft.id}
                data-confirm="Delete this draft?"
                class="btn btn-ghost btn-sm text-error"
              >
                Delete
              </button>
            </div>
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
