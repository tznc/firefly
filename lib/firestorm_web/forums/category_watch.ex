defmodule FirestormWeb.Forums.CategoryWatch do
  @moduledoc "A user's notification level for a category (applies to its threads)."
  use Ecto.Schema

  schema "forums_categories_watches" do
    field(:assoc_id, :integer)
    field(:user_id, :integer)
    field(:level, :string)

    timestamps(type: :naive_datetime_usec)
  end
end
