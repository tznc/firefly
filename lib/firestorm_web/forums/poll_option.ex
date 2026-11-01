defmodule FirestormWeb.Forums.PollOption do
  @moduledoc "One of a poll's options, in `position` order (see `FirestormWeb.Polls`)."

  use Ecto.Schema

  schema "forums_poll_options" do
    field(:position, :integer)
    field(:text, :string)
    belongs_to(:poll, FirestormWeb.Forums.Poll)
  end
end
