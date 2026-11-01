defmodule FirestormWeb.Forums.Message do
  @moduledoc "A message in a private conversation (markdown, like a post)."

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{Conversation, User}

  schema "forums_messages" do
    field(:body, :string)
    belongs_to(:conversation, Conversation)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = message, attrs) do
    message
    |> cast(attrs, [:body])
    |> validate_required([:body])
  end
end
