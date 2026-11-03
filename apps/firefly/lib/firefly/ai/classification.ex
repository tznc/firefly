defmodule Firefly.AI.Classification do
  @moduledoc """
  Triage's rating of a post (see `Firefly.AI.Triage`): `toxicity` and
  `spam` from 0 to 100, `sentiment` (`positive`, `neutral` or
  `negative`) and the model's `reason`, for moderators.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @sentiments ~w(positive neutral negative)

  schema "ai_post_classifications" do
    belongs_to(:post, Firefly.Discussion.Post)
    field(:toxicity, :integer)
    field(:spam, :integer)
    field(:sentiment, :string)
    field(:reason, :string)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  @doc "The sentiments, in display order."
  def sentiments, do: @sentiments

  @doc "A classification from a model's JSON answer; scores are clamped to 0..100."
  def changeset(%__MODULE__{} = classification, json) do
    classification
    |> cast(
      %{
        toxicity: score(json["toxicity"]),
        spam: score(json["spam"]),
        sentiment: json["sentiment"],
        reason: if(is_binary(json["reason"]), do: String.slice(json["reason"], 0, 500))
      },
      [:toxicity, :spam, :sentiment, :reason]
    )
    |> validate_required([:toxicity, :spam, :sentiment])
    |> validate_inclusion(:sentiment, @sentiments)
  end

  defp score(value) when is_number(value), do: value |> round() |> max(0) |> min(100)
  defp score(_value), do: nil
end
