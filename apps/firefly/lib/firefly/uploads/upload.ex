defmodule Firefly.Uploads.Upload do
  @moduledoc """
  A file a member uploaded (see `Firefly.Uploads`).

  `token` is the random, unguessable id in its URL (`/uploads/:token/:name`).
  The stored file is named by `sha256` (of the file as uploaded), so the
  same content is stored once; `size`, `content_type` and, for images,
  `width` and `height` describe the stored (processed) file. `thumbnail`:
  whether a smaller copy exists, for images larger than the thumbnail size.

  `attached_to` says what it belongs to, which decides who may fetch it:
  `"post"` (`post_id`), `"message"` (`message_id`) or `"chat"`
  (`chat_message_id`, see `Firefly.Chat`), whoever may read that; `"avatar"`, the uploader's profile picture, `"background"`, their
  profile or user card background, and `"emoji"`, a
  custom emoji (see `Firefly.Rendering.Emoji`), and `"preview"`, a link
  preview's image (see `Firefly.Rendering.LinkPreviews`), anyone. Nil: nothing
  yet (just uploaded in a composer), the uploader and admins only, and
  removed after a grace period.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Discussion.Post
  alias Firefly.Chat
  alias Firefly.Messaging.Message

  @kinds ~w(post message chat avatar background emoji preview)

  schema "uploads" do
    field(:token, :string)
    field(:filename, :string)
    field(:content_type, :string)
    field(:size, :integer)
    field(:sha256, :string)
    field(:width, :integer)
    field(:height, :integer)
    field(:thumbnail, :boolean, default: false)
    field(:attached_to, :string)
    field(:attached_at, :utc_datetime)
    belongs_to(:user, User)
    belongs_to(:post, Post)
    belongs_to(:message, Message)
    belongs_to(:chat_message, Chat.Message)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "What an upload can be attached to."
  def kinds, do: @kinds

  @doc "Whether the upload is an image (shown inline, not downloaded)."
  def image?(%__MODULE__{content_type: "image/" <> _}), do: true
  def image?(%__MODULE__{}), do: false
end
