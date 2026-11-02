defmodule FirestormWeb.Web.Editor do
  @moduledoc """
  Shared pieces of the post editor used by the new thread and reply pages:
  a markdown textarea with a live preview, `@username` autocomplete, file
  attachments (picked, dropped on the editor or pasted into it; stored by
  `FirestormWeb.Uploads`), an emoji picker and `:emoji` autocomplete (see
  `FirestormWeb.Emoji`), and the toolbar
  buttons plugins add (they insert text; see `FirestormWeb.Plugin.Manifest`).
  The preview shows plain markdown: plugins only transform published posts.
  """
  use FirestormWeb.Web, :html

  import Phoenix.LiveView,
    only: [
      allow_upload: 3,
      attach_hook: 4,
      consume_uploaded_entry: 3,
      push_event: 3,
      put_flash: 3
    ]

  alias FirestormWeb.{Forums, Markdown, Plugins, RateLimit, Uploads}

  @max_entries 5

  @doc """
  Allows a few attachments at a time, each uploaded as soon as it's picked,
  dropped or pasted, up to the `max_upload_kb` site setting.
  """
  def allow_attachments(socket, progress) do
    allow_upload(socket, :attachment,
      accept: Uploads.accept(),
      max_entries: @max_entries,
      max_file_size: Uploads.max_size(),
      auto_upload: true,
      progress: progress
    )
  end

  @doc """
  For a composer's upload progress callback: once `entry` has arrived,
  stores it (see `FirestormWeb.Uploads.create/4`) and calls `insert` with
  the socket and the markdown showing it; a refused file is a flash error.
  Returns `{:noreply, socket}`.
  """
  def attachment_progress(socket, entry, insert) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Uploads.create(socket.assigns.current_user, path, entry.client_name)}
        end)

      case result do
        {:ok, upload} -> inserted(insert, socket, Uploads.markdown(upload))
        {:error, :rate_limited} -> {:noreply, put_flash(socket, :error, RateLimit.message())}
        {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  # LiveView leaves a focused textarea's value alone (e.g. right after a
  # paste), so the `PasteUpload` hook appends the markdown itself then.
  defp inserted(insert, socket, markdown) do
    {:noreply, socket} = insert.(socket, markdown)
    {:noreply, push_event(socket, "attachment_added", %{markdown: markdown})}
  end

  @doc """
  Answers the `MentionAutocomplete` hook's `"mention_search"` event (a
  username prefix) with matching users, for whichever LiveView hosts the
  editor.
  """
  def mention_search(socket) do
    attach_hook(socket, :mention_search, :handle_event, fn
      "mention_search", %{"prefix" => prefix}, socket ->
        {:halt, %{users: mention_matches(prefix)}, socket}

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  defp mention_matches(prefix) when is_binary(prefix) do
    if prefix =~ ~r/^[A-Za-z0-9_-]{1,32}$/ do
      for user <- Forums.search_usernames(prefix), do: Map.take(user, [:username, :name])
    else
      []
    end
  end

  defp mention_matches(_prefix), do: []

  @doc "Appends an attachment's markdown to a body."
  def append(body, markdown) when body in [nil, ""], do: markdown
  def append(body, markdown), do: "#{body}\n\n#{markdown}"

  @doc "The markdown textarea, attachment picker and live preview."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :uploads, :map, required: true
  attr :placeholder, :string, default: "Type post content here. Use markdown syntax."
  attr :user, :any, default: nil, doc: "the writer, for plugins' composer widgets"

  def body_editor(assigns) do
    assigns =
      assigns
      |> assign(:buttons, composer_buttons())
      |> assign(:custom_emoji, custom_emoji_json())

    ~H"""
    <div class="space-y-3">
      <div
        id={"#{@field.id}-dropzone"}
        class="relative rounded-box"
        phx-drop-target={@uploads.attachment.ref}
        phx-hook="PasteUpload"
        data-upload="attachment"
      >
        <.input
          field={@field}
          type="textarea"
          label="Body"
          rows="8"
          placeholder={@placeholder}
          phx-debounce="300"
          phx-hook="MentionAutocomplete"
          data-menu={"#{@field.id}-mentions"}
          data-custom-emoji={@custom_emoji}
          class="textarea w-full font-mono text-sm"
        />
        <ul
          id={"#{@field.id}-mentions"}
          phx-update="ignore"
          role="listbox"
          aria-label="Suggestions"
          class="menu absolute top-full left-0 z-20 hidden w-64 rounded-box border border-base-300 bg-base-100 p-1 shadow"
        >
        </ul>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <div
          id={"#{@field.id}-emoji"}
          class="relative"
          phx-hook="EmojiPicker"
          phx-update="ignore"
          data-target={@field.id}
          data-custom-emoji={@custom_emoji}
        >
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            data-toggle
            aria-haspopup="true"
            aria-expanded="false"
          >
            <.icon name="hero-face-smile" class="size-4" /> Emoji
          </button>
          <div
            data-panel
            hidden
            role="dialog"
            aria-label="Emoji"
            class="absolute bottom-full left-0 z-30 mb-1 w-80 rounded-box border border-base-300 bg-base-100 p-2 shadow"
          >
            <input
              type="search"
              class="input input-sm mb-2 w-full"
              placeholder="Search emoji"
              aria-label="Search emoji"
            />
            <div data-grid class="grid max-h-64 grid-cols-8 overflow-y-auto"></div>
          </div>
        </div>
        <div
          :if={@buttons != []}
          id={"#{@field.id}-plugin-buttons"}
          phx-hook="ComposerButtons"
          data-target={@field.id}
          class="join"
          aria-label="Insert"
        >
          <button
            :for={button <- @buttons}
            type="button"
            class="btn btn-ghost btn-sm join-item"
            data-insert={button.insert}
            title={"Inserts: " <> button.insert}
          >
            {button.label}
          </button>
        </div>
        <label
          class="btn btn-ghost btn-sm"
          for={@uploads.attachment.ref}
          title="Or drop files on the editor, or paste them into it"
        >
          <.icon name="hero-paper-clip" class="size-4" /> Attach files
        </label>
        <.live_file_input upload={@uploads.attachment} class="hidden" aria-label="add-attachment" />
        <div :for={entry <- @uploads.attachment.entries} class="flex items-center gap-2 text-sm">
          <span>{entry.client_name}</span>
          <progress class="progress progress-primary w-24" value={entry.progress} max="100" />
          <span :for={err <- upload_errors(@uploads.attachment, entry)} class="text-error">
            {upload_error(err)}
          </span>
        </div>
        <p
          :for={err <- upload_errors(@uploads.attachment)}
          class="text-sm text-error"
        >
          {upload_error(err)}
        </p>
      </div>
      <FirestormWeb.Web.PluginComponents.plugin_outlet
        outlet="composer"
        key={@field.id}
        context={%{field: @field.id}}
        user={@user}
      />
      <section class="rounded-box border border-dashed border-base-300 p-4" aria-label="Preview">
        <h2 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Preview
        </h2>
        <div id="post-preview" phx-hook="Highlight" class="post-body prose prose-sm max-w-none">
          {raw(Markdown.render(@field.value))}
        </div>
      </section>
    </div>
    """
  end

  defp custom_emoji_json do
    Jason.encode!(for {name, url} <- FirestormWeb.Emoji.custom(), do: %{name: name, url: url})
  end

  # Toolbar buttons the active plugins declare (manifest `composer_buttons`),
  # in plugin order.
  defp composer_buttons do
    for plugin <- Plugins.active(), button <- plugin.manifest.composer_buttons do
      %{label: button["label"], insert: button["insert"]}
    end
  end

  defp upload_error(:too_large),
    do: "That file is too large (#{div(Uploads.max_size(), 1024)} KB max)."

  defp upload_error(:not_accepted), do: "That file type isn't allowed."
  defp upload_error(:too_many_files), do: "Attach at most #{@max_entries} files at a time."
  defp upload_error(other), do: "Upload error: #{other}"
end
