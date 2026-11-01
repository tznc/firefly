defmodule FirestormWeb.Forums.ThreadRead do
  @moduledoc "How far a user has read a thread: the newest post they've seen."
  use Ecto.Schema

  schema "forums_thread_reads" do
    field(:user_id, :integer)
    field(:thread_id, :integer)
    field(:last_read_post_id, :integer)

    timestamps(type: :naive_datetime_usec)
  end
end
