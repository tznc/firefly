defmodule FirestormWeb.Web.Drafting do
  @moduledoc """
  Draft autosave for the composer LiveViews (see `FirestormWeb.Drafts`):
  `assign_draft/2` on mount loads the draft to restore, `autosave/2` on
  each form change saves it, `discard_draft/1` drops it, and
  `draft_status/1` shows that it's saved with a "Discard draft" button
  (which sends `discard_draft`).
  """
  use FirestormWeb.Web, :html

  alias FirestormWeb.Drafts

  @doc "Assigns the user's `:draft` for `context` (nil if none) for the composer to restore."
  def assign_draft(socket, context) do
    socket
    |> assign(:draft_context, context)
    |> assign(:draft, Drafts.get(socket.assigns.current_user, context))
    |> assign(:draft_error, nil)
  end

  @doc "Saves the form's content (`title`, `tags`, `body`) as the draft."
  def autosave(socket, attrs) do
    case Drafts.save(socket.assigns.current_user, socket.assigns.draft_context, attrs) do
      {:ok, draft} -> assign(socket, draft: draft, draft_error: nil)
      {:error, :too_many} -> assign(socket, :draft_error, Drafts.message(:too_many))
      # Too long to keep: the form shows why.
      {:error, %Ecto.Changeset{}} -> socket
    end
  end

  @doc "Deletes the draft (sent, or discarded)."
  def discard_draft(socket) do
    :ok = Drafts.discard(socket.assigns.current_user, socket.assigns.draft_context)
    assign(socket, draft: nil, draft_error: nil)
  end

  @doc "Whether the draft was saved, with a button to discard it."
  attr :draft, :any, required: true
  attr :error, :string, default: nil

  def draft_status(assigns) do
    ~H"""
    <div :if={@draft || @error} id="draft-status" class="flex items-center gap-2 text-sm text-base-content/70">
      <span :if={@error} class="text-warning">{@error}</span>
      <span :if={@draft && !@error}>
        <.icon name="hero-document-check" class="size-4" /> Draft saved
        <.time_ago id="draft-saved-at" at={@draft.updated_at} />
      </span>
      <button
        :if={@draft}
        type="button"
        phx-click="discard_draft"
        data-confirm="Discard this draft?"
        class="btn btn-ghost btn-xs"
      >
        Discard draft
      </button>
    </div>
    """
  end
end
