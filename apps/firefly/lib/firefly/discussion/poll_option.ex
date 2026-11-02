defmodule Firefly.Discussion.PollOption do
  @moduledoc "One of a poll's options, in `position` order (see `Firefly.Discussion.Polls`)."

  use Ecto.Schema

  schema "forums_poll_options" do
    field(:position, :integer)
    field(:text, :string)
    belongs_to(:poll, Firefly.Discussion.Poll)
  end
end
