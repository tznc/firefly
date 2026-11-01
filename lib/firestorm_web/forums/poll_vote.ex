defmodule FirestormWeb.Forums.PollVote do
  @moduledoc """
  One option a user chose in a poll (see `FirestormWeb.Polls`); in a
  ranked-choice poll, with its `rank` (1: first choice).
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.{Poll, PollOption, User}

  schema "forums_poll_votes" do
    field(:rank, :integer)
    belongs_to(:poll, Poll)
    belongs_to(:option, PollOption)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
