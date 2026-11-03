defmodule Firefly.AI.Usage do
  @moduledoc """
  The AI usage log: requests and tokens per day, feature and member (nil:
  work the system did by itself, like triage). Daily quotas count a
  member's requests here (see `Firefly.AI.quota/1`); staff see the log at
  `/staff/ai` and the `ai_usage` report.
  """
  use Ecto.Schema

  import Ecto.Query

  alias Firefly.Accounts.User
  alias Firefly.Repo

  schema "ai_usage" do
    field(:day, :date)
    field(:feature, :string)
    belongs_to(:user, User)
    field(:requests, :integer, default: 0)
    field(:input_tokens, :integer, default: 0)
    field(:output_tokens, :integer, default: 0)
  end

  @doc "Adds a request and its tokens to today's row for `feature` and `user_id`."
  def record(feature, user_id, %{input_tokens: input, output_tokens: output}) do
    Repo.insert_all(
      __MODULE__,
      [
        %{
          day: Date.utc_today(),
          feature: feature,
          user_id: user_id,
          requests: 1,
          input_tokens: input,
          output_tokens: output
        }
      ],
      on_conflict: [inc: [requests: 1, input_tokens: input, output_tokens: output]],
      conflict_target: [:day, :feature, :user_id]
    )

    :ok
  end

  @doc "The requests `user_id` made today, every feature together."
  def requests_today(user_id) do
    Repo.one(
      from(u in __MODULE__,
        where: u.user_id == ^user_id and u.day == ^Date.utc_today(),
        select: coalesce(sum(u.requests), 0)
      )
    )
  end

  @doc "The latest rows (the last `days` days), busiest first each day, with their users."
  def recent(days \\ 30, limit \\ 200) do
    Repo.all(
      from(u in __MODULE__,
        where: u.day > ^Date.add(Date.utc_today(), -days),
        order_by: [desc: u.day, desc: u.input_tokens + u.output_tokens, asc: u.feature],
        limit: ^limit,
        preload: :user
      )
    )
  end
end
