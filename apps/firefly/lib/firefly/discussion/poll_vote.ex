defmodule Firefly.Discussion.PollVote do
  @moduledoc """
  One option a user chose in a poll (see `Firefly.Discussion.Polls`); in a
  ranked-choice poll, with its `rank` (1: first choice).
  """

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Poll, PollOption}

  schema "forums_poll_votes" do
    field(:rank, :integer)
    belongs_to(:poll, Poll)
    belongs_to(:option, PollOption)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
