defmodule Firefly.AI.Summary do
  @moduledoc """
  A topic's cached summary (see `Firefly.AI.Summaries`) and how many posts
  it covered.
  """
  use Ecto.Schema

  schema "ai_summaries" do
    belongs_to(:thread, Firefly.Discussion.Thread)
    field(:content, :string)
    field(:post_count, :integer)

    timestamps(type: :naive_datetime_usec)
  end
end
