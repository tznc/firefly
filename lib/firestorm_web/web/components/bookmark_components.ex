defmodule FirestormWeb.Web.BookmarkComponents do
  @moduledoc """
  Bookmark UI (see `FirestormWeb.Bookmarks`): the toggle on posts and the
  note and reminder form, shared by thread pages and `/bookmarks`.
  """
  use Phoenix.Component

  import FirestormWeb.Web.CoreComponents, only: [icon: 1, input: 1, button: 1]

  alias FirestormWeb.Bookmarks

  @doc """
  The browser's offset from UTC in minutes (`getTimezoneOffset()`, sent as a
  connect param by app.js), so reminder times mean local time. 0 (UTC)
  until connected.
  """
  def tz_offset(socket) do
    case Phoenix.LiveView.connected?(socket) &&
           Phoenix.LiveView.get_connect_params(socket)["tz_offset"] do
      offset when is_integer(offset) and abs(offset) <= 14 * 60 -> offset
      _unknown -> 0
    end
  end

  @doc "The form's params for `bookmark`: its note and current reminder."
  def form_params(bookmark, offset) do
    %{
      "note" => bookmark.note,
      "reminder" => if(bookmark.remind_at, do: "custom", else: ""),
      "custom_at" => Bookmarks.to_local_input(bookmark.remind_at, offset)
    }
  end

  @doc "A toggle to bookmark a post (sends `toggle_bookmark` with its `id`)."
  attr :post, :any, required: true
  attr :bookmarked, :boolean, required: true

  def bookmark_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_bookmark"
      phx-value-id={@post.id}
      class={["bookmark-toggle btn btn-ghost btn-sm btn-square", @bookmarked && "text-primary"]}
      aria-label={if @bookmarked, do: "Remove bookmark of post #{@post.id}", else: "Bookmark post #{@post.id}"}
      aria-pressed={to_string(@bookmarked)}
      title={if @bookmarked, do: "Remove bookmark", else: "Bookmark"}
    >
      <.icon name={if @bookmarked, do: "hero-bookmark-solid", else: "hero-bookmark"} class="size-4" />
    </button>
    """
  end

  @doc """
  The note and reminder form for a bookmark: sends `save_bookmark` (with
  `bookmark` params, see `FirestormWeb.Bookmarks.update/4`) and
  `cancel_bookmark`.
  """
  attr :form, :any, required: true
  attr :id, :string, default: "bookmark-form"

  def bookmark_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id={@id}
      phx-submit="save_bookmark"
      class="mt-2 space-y-2 rounded-box border border-primary/40 bg-base-100 p-4"
    >
      <.input field={@form[:note]} type="text" label="Note (optional)" maxlength="500" />
      <div class="flex flex-wrap items-end gap-2">
        <.input
          field={@form[:reminder]}
          type="select"
          label="Remind me"
          options={[{"No reminder", ""} | Bookmarks.presets()] ++ [{"At a time…", "custom"}]}
        />
        <.input field={@form[:custom_at]} type="datetime-local" label="Time (for “At a time…”)" />
      </div>
      <p :for={{message, _} <- @form[:remind_at].errors} class="text-sm text-error">
        Reminder {message}
      </p>
      <div class="flex justify-end gap-2">
        <button type="button" phx-click="cancel_bookmark" class="btn btn-ghost btn-sm">Close</button>
        <.button variant="primary" class="btn-sm">Save</.button>
      </div>
    </.form>
    """
  end
end
