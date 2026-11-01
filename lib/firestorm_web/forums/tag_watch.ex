defmodule FirestormWeb.Forums.TagWatch do
  @moduledoc "A user's notification level for a tag (applies to threads with it)."
  use Ecto.Schema

  schema "forums_tags_watches" do
    field(:assoc_id, :integer)
    field(:user_id, :integer)
    field(:level, :string)

    timestamps(type: :naive_datetime_usec)
  end
end
