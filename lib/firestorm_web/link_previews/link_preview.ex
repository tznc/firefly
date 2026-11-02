defmodule FirestormWeb.LinkPreviews.LinkPreview do
  @moduledoc """
  A cached link preview (see `FirestormWeb.LinkPreviews`), keyed by the
  sha256 of its URL. `status`: `"pending"` (being fetched), `"ok"` (has a
  title) or `"failed"` (nothing to show). `image_upload` is the page's
  image, copied into uploads; never a link to another site's image.
  """

  use Ecto.Schema

  alias FirestormWeb.Uploads.Upload

  schema "link_previews" do
    field(:url_hash, :string)
    field(:url, :string)
    field(:status, :string)
    field(:title, :string)
    field(:description, :string)
    field(:site_name, :string)
    field(:expires_at, :utc_datetime)
    belongs_to(:image_upload, Upload)

    timestamps(type: :naive_datetime_usec)
  end
end
