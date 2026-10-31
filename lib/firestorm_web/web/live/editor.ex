defmodule FirestormWeb.Web.Editor do
  @moduledoc """
  Shared pieces of the post editor used by the new thread and reply pages:
  a markdown textarea with a live preview, and file attachments uploaded
  straight from the browser to S3.
  """
  use FirestormWeb.Web, :html

  import Phoenix.LiveView, only: [allow_upload: 3, consume_uploaded_entry: 3]

  alias FirestormWeb.{Markdown, Uploads}

  @image_types ~w(image/png image/jpeg image/jpg image/gif image/webp)

  @doc "Allows one attachment at a time, uploaded to S3 as soon as it is picked."
  def allow_attachments(socket, progress) do
    allow_upload(socket, :attachment,
      accept: :any,
      max_entries: 1,
      max_file_size: 10_000_000,
      auto_upload: true,
      external: &presign/2,
      progress: progress
    )
  end

  defp presign(entry, socket) do
    {:ok, signature} = Uploads.sign(entry.client_name, entry.client_type)

    meta = %{
      uploader: "S3",
      key: signature.key,
      url: signature.action,
      fields: %{
        "key" => signature.key,
        "AWSAccessKeyId" => signature.aws_access_key_id,
        "acl" => signature.acl,
        "success_action_status" => signature.success_action_status,
        "policy" => signature.policy,
        "signature" => signature.signature,
        "Content-Type" => signature.content_type
      }
    }

    {:ok, meta, socket}
  end

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
    ~H"""
    <div class="space-y-3">
      <.input
        field={@field}
        type="textarea"
        rows="8"
        placeholder={@placeholder}
        phx-debounce="300"
        class="textarea w-full font-mono text-sm"
      />
      <div class="flex items-center gap-3">
        <label class="btn btn-ghost btn-sm" for={@uploads.attachment.ref}>
          <.icon name="hero-paper-clip" class="size-4" /> Attach a file
        </label>
        <.live_file_input upload={@uploads.attachment} class="hidden" aria-label="add-attachment" />
        <div :for={entry <- @uploads.attachment.entries} class="flex items-center gap-2 text-sm">
          <span>{entry.client_name}</span>
          <progress class="progress progress-primary w-24" value={entry.progress} max="100" />
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

  defp upload_error(:too_large), do: "That file is too large (10 MB max)."
  defp upload_error(:too_many_files), do: "Attach one file at a time."
  defp upload_error(:external_client_failure), do: "The upload failed. Please try again."
  defp upload_error(other), do: "Upload error: #{other}"
end
