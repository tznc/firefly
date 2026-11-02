defmodule FirestormWeb.Web.Editor do
  @moduledoc """
  Shared pieces of the post editor used by the new thread and reply pages:
  a markdown textarea with a live preview, `@username` autocomplete, file
  attachments uploaded straight from the browser to S3, and the toolbar
  buttons plugins add (they insert text; see `FirestormWeb.Plugin.Manifest`).
  The preview shows plain markdown: plugins only transform published posts.
  """
  use FirestormWeb.Web, :html

  import Phoenix.LiveView, only: [allow_upload: 3, attach_hook: 4, consume_uploaded_entry: 3]

  alias FirestormWeb.{Forums, Markdown, Plugins, Uploads}

  @image_types ~w(image/png image/jpeg image/jpg image/gif image/webp)

  @doc "Allows one attachment at a time, uploaded to S3 as soon as it is picked."
  def allow_attachments(socket, progress) do
    allow_upload(socket, :attachment,
      accept: ~w(.png .jpg .jpeg .gif .webp .pdf .txt),
      max_entries: 1,
      max_file_size: Uploads.max_size(),
      auto_upload: true,
      external: &presign/2,
      progress: progress
    )
  end

  defp presign(entry, socket) do
    with :ok <- FirestormWeb.RateLimit.check_upload(socket.assigns.current_user),
         {:ok, signature} <- Uploads.sign(entry.client_name, entry.client_type) do
      meta = %{
        uploader: "S3",
        key: signature.key,
        url: signature.action,
        fields: signature.fields
      }

      {:ok, meta, socket}
    else
      {:error, _reason} -> {:error, %{reason: :not_allowed}, socket}
    end
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

  @doc """
  Consumes a finished upload and returns the markdown that links to it
  (an image for image types, a plain link otherwise).
  """
  def consume_attachment(socket, entry) do
    consume_uploaded_entry(socket, entry, fn %{url: url, key: key} ->
      {:ok, attachment_markdown(entry.client_name, entry.client_type, "#{url}/#{key}")}
    end)
  end

  @doc false
  def attachment_markdown(filename, type, location) when type in @image_types,
    do: "![#{filename}](#{location})"

  def attachment_markdown(filename, _type, location), do: "[#{filename}](#{location})"

  @doc "Appends an attachment's markdown to a body."
  def append(body, markdown) when body in [nil, ""], do: markdown
  def append(body, markdown), do: "#{body}\n\n#{markdown}"

  @doc "The markdown textarea, attachment picker and live preview."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :uploads, :map, required: true
  attr :placeholder, :string, default: "Type post content here. Use markdown syntax."

  def body_editor(assigns) do
    assigns = assign(assigns, :buttons, composer_buttons())

    ~H"""
    <div class="space-y-3">
      <div class="relative">
        <.input
          field={@field}
          type="textarea"
          label="Body"
          rows="8"
          placeholder={@placeholder}
          phx-debounce="300"
          phx-hook="MentionAutocomplete"
          data-menu={"#{@field.id}-mentions"}
          class="textarea w-full font-mono text-sm"
        />
        <ul
          id={"#{@field.id}-mentions"}
          phx-update="ignore"
          role="listbox"
          aria-label="Mention suggestions"
          class="menu absolute top-full left-0 z-20 hidden w-64 rounded-box border border-base-300 bg-base-100 p-1 shadow"
        >
        </ul>
      </div>
      <div class="flex flex-wrap items-center gap-3">
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
        <label class="btn btn-ghost btn-sm" for={@uploads.attachment.ref}>
          <.icon name="hero-paper-clip" class="size-4" /> Attach a file
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

  # Toolbar buttons the active plugins declare (manifest `composer_buttons`),
  # in plugin order.
  defp composer_buttons do
    for plugin <- Plugins.active(), button <- plugin.manifest.composer_buttons do
      %{label: button["label"], insert: button["insert"]}
    end
  end

  defp upload_error(:too_large), do: "That file is too large (10 MB max)."
  defp upload_error(:not_accepted), do: "That file type isn't allowed."
  defp upload_error(:too_many_files), do: "Attach one file at a time."
  defp upload_error(:external_client_failure), do: "The upload failed. Please try again."

  defp upload_error(%{reason: :not_allowed}),
    do: "Uploads are limited right now. Please try again later."

  defp upload_error(other), do: "Upload error: #{other}"
end
