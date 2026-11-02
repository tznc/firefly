defmodule Firefly.Forums.PollOption do
  @moduledoc "One of a poll's options, in `position` order (see `Firefly.Polls`)."

  use Ecto.Schema

  schema "forums_poll_options" do
    field(:position, :integer)
    field(:text, :string)
    belongs_to(:poll, Firefly.Forums.Poll)
  end
end
