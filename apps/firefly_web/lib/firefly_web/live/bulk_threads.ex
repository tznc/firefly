defmodule FireflyWeb.BulkThreads do
  @moduledoc """
  Selecting threads in a thread list and acting on them all at once (see
  `Firefly.Moderation.BulkActions`): members can mark them read, staff
  (and leaders, regulars, as the policies allow) moderate them.

  A LiveView with a `thread_list` calls `init/1` when it mounts, passes
  `selected={@selected}` to the list, renders `bar/1` above it, and hands
  the `"bulk_" <> _` events to `handle_event/4` with a function that
  reloads its threads. Nothing is selectable without a signed-in user.
  """
  use FireflyWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Firefly.Discussion
  alias Firefly.Moderation.BulkActions

  @labels %{
    "mark_read" => "Mark read",
    "close" => "Close",
    "open" => "Open",
    "pin" => "Pin",
    "unpin" => "Unpin",
    "archive" => "Archive",
    "unarchive" => "Unarchive",
    "delete" => "Delete"
  }

  @doc "Assigns `selected` (nil for visitors), the actions on offer and move targets."
  def init(socket) do
    user = socket.assigns.current_user
    actions = BulkActions.actions_for(user)

    assign(socket,
      selected: user && MapSet.new(),
      bulk_actions: actions,
      bulk_categories:
        if("move" in actions,
          do: Enum.map(Discussion.list_categories(user), &{&1.title, &1.id}),
          else: []
        )
    )
  end

  @doc "Handles a `bulk_*` event; `reload` reloads the page's threads."
  def handle_event(_event, _params, %{assigns: %{selected: nil}} = socket, _reload),
    do: {:noreply, socket}

  def handle_event("bulk_select", %{"id" => id}, socket, _reload) do
    id = String.to_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("bulk_select_all", _params, socket, _reload),
    do: {:noreply, assign(socket, :selected, MapSet.new(socket.assigns.threads, & &1.id))}

  def handle_event("bulk_clear", _params, socket, _reload),
    do: {:noreply, assign(socket, :selected, MapSet.new())}

  def handle_event("bulk_apply", %{"action" => action} = params, socket, reload) do
    ids = MapSet.to_list(socket.assigns.selected)

    case BulkActions.perform(socket.assigns.current_user, ids, action, params) do
      {:ok, %{done: done, skipped: skipped}} ->
        {:noreply,
         socket
         |> put_flash(:info, done_message(done, skipped))
         |> assign(:selected, MapSet.new())
         |> reload.()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BulkActions.message(reason))}
    end
  end

  defp done_message(done, 0), do: "Updated #{threads(done)}."

  defp done_message(done, skipped),
    do: "Updated #{threads(done)}; skipped #{threads(skipped)} you can't change that way."

  defp threads(1), do: "1 thread"
  defp threads(count), do: "#{count} threads"

  @doc "The selection bar: select all or none, and the actions for the selection."
  attr :selected, :any, required: true
  attr :actions, :list, required: true
  attr :categories, :list, default: []

  def bar(assigns) do
    assigns = assign(assigns, :labels, @labels)

    ~H"""
    <div :if={@selected} id="bulk-actions" class="flex flex-wrap items-center gap-2 text-sm">
      <button type="button" phx-click="bulk_select_all" class="btn btn-ghost btn-xs">Select all</button>
      <%= if MapSet.size(@selected) > 0 do %>
        <button type="button" phx-click="bulk_clear" class="btn btn-ghost btn-xs">Clear</button>
        <span id="bulk-count" class="font-medium">{MapSet.size(@selected)} selected:</span>
        <button
          :for={action <- Enum.filter(@actions, &Map.has_key?(@labels, &1))}
          type="button"
          phx-click="bulk_apply"
          phx-value-action={action}
          data-confirm={action == "delete" && "Delete the selected threads?"}
          class={["btn btn-xs", action == "delete" && "btn-error"]}
        >
          {@labels[action]}
        </button>
        <form :if={"move" in @actions} id="bulk-move" phx-submit="bulk_apply" class="join">
          <input type="hidden" name="action" value="move" />
          <select name="category_id" aria-label="Move to category" class="select select-xs join-item">
            {Phoenix.HTML.Form.options_for_select(@categories, nil)}
          </select>
          <button class="btn btn-xs join-item">Move</button>
        </form>
        <form :if={"add_tags" in @actions} id="bulk-tags" phx-submit="bulk_apply" class="join">
          <select name="action" aria-label="Tag action" class="select select-xs join-item">
            {Phoenix.HTML.Form.options_for_select(
              [{"Add tags", "add_tags"}, {"Remove tags", "remove_tags"}],
              "add_tags"
            )}
          </select>
          <input type="text" name="tags" aria-label="Tags" placeholder="tags" class="input input-xs join-item w-32" />
          <button class="btn btn-xs join-item">Apply</button>
        </form>
      <% end %>
    </div>
    """
  end
end
