defmodule FirestormWeb.Emoji.CustomEmoji do
  @moduledoc "An emoji an admin added (see `FirestormWeb.Emoji`): `:name:` shows `upload`."

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.User
  alias FirestormWeb.Uploads.Upload

  schema "custom_emoji" do
    field(:name, :string)
    belongs_to(:upload, Upload)
    belongs_to(:created_by, User)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(emoji, attrs) do
    emoji
    |> cast(attrs, [:name])
    |> update_change(:name, &String.downcase(String.trim(&1)))
    |> validate_required([:name])
    |> validate_format(:name, ~r/\A[a-z0-9_]{2,32}\z/,
      message: "use 2 to 32 lowercase letters, digits and underscores"
    )
    |> validate_standard()
    |> unique_constraint(:name, message: "is already taken")
  end

  # Only a well-formed name is worth comparing.
  defp validate_standard(%{valid?: true} = changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if FirestormWeb.Emoji.standard?(name), do: [name: "is already a standard emoji"], else: []
    end)
  end

  defp validate_standard(changeset), do: changeset
end
