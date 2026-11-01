defmodule FirestormWeb.Forums.Poll do
  @moduledoc """
  A post's poll (see `FirestormWeb.Polls`). `kind` is `"single"` (one
  choice), `"multiple"` (between `min_choices` and `max_choices`) or
  `"ranked"` (rank some or all options; instant-runoff results).
  `results` says when voters see the results: `"always"`, `"voted"` (once
  they've voted) or `"closed"` (once the poll closes). Voters are listed by
  name if `public`. It closes at `close_at`, if set, or when its author or
  staff close it (`closed_at`).

  Options are given as `options_text`, one per line, and kept in order.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{Post, PollOption, PollVote}

  @kinds ~w(single multiple ranked)
  @results ~w(always voted closed)
  @max_options 20

  def kinds, do: @kinds
  def results_options, do: @results
  def max_options, do: @max_options

  schema "forums_polls" do
    field(:kind, :string, default: "single")
    field(:min_choices, :integer)
    field(:max_choices, :integer)
    field(:results, :string, default: "always")
    field(:public, :boolean, default: false)
    field(:close_at, :utc_datetime)
    field(:closed_at, :utc_datetime)
    field(:options_text, :string, virtual: true)
    belongs_to(:post, Post)
    has_many(:options, PollOption, preload_order: [asc: :position])
    has_many(:votes, PollVote)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "A new poll, from the composer."
  def changeset(%__MODULE__{} = poll, attrs) do
    poll
    |> cast(attrs, [
      :kind,
      :min_choices,
      :max_choices,
      :results,
      :public,
      :close_at,
      :options_text
    ])
    |> validate_required([:kind, :results])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:results, @results)
    |> put_options()
    |> validate_choices()
    |> validate_change(:close_at, fn :close_at, at ->
      if DateTime.after?(at, DateTime.utc_now()),
        do: [],
        else: [close_at: "must be in the future"]
    end)
  end

  defp put_options(changeset) do
    texts =
      (get_field(changeset, :options_text) || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      length(texts) < 2 ->
        add_error(changeset, :options_text, "needs at least 2 options")

      length(texts) > @max_options ->
        add_error(changeset, :options_text, "can have at most #{@max_options} options")

      Enum.any?(texts, &(String.length(&1) > 200)) ->
        add_error(changeset, :options_text, "options can be at most 200 characters")

      length(Enum.uniq_by(texts, &String.downcase/1)) != length(texts) ->
        add_error(changeset, :options_text, "has the same option twice")

      true ->
        options =
          texts
          |> Enum.with_index(1)
          |> Enum.map(fn {t, i} -> %PollOption{position: i, text: t} end)

        put_assoc(changeset, :options, options)
    end
  end

  # Multiple choice: 1 <= min <= max <= the number of options (defaults: 1
  # and all of them). The others don't use them.
  defp validate_choices(changeset) do
    if get_field(changeset, :kind) == "multiple" do
      count = length(get_field(changeset, :options) || [])
      min = get_field(changeset, :min_choices) || 1
      max = get_field(changeset, :max_choices) || max(count, 1)

      changeset
      |> put_change(:min_choices, min)
      |> put_change(:max_choices, max)
      |> validate_number(:min_choices, greater_than_or_equal_to: 1)
      |> validate_number(:max_choices, greater_than_or_equal_to: min)
      |> then(
        &if(count > 0,
          do: validate_number(&1, :max_choices, less_than_or_equal_to: count),
          else: &1
        )
      )
    else
      changeset |> put_change(:min_choices, nil) |> put_change(:max_choices, nil)
    end
  end

  @doc "Whether the poll is closed at `now`: closed by hand, or past `close_at`."
  def closed?(%__MODULE__{} = poll, now \\ DateTime.utc_now()) do
    not is_nil(poll.closed_at) or
      (not is_nil(poll.close_at) and not DateTime.after?(poll.close_at, now))
  end

  @doc "The kind, for people."
  def kind_label("single"), do: "Single choice"
  def kind_label("multiple"), do: "Multiple choice"
  def kind_label("ranked"), do: "Ranked choice"

  @doc "When results show, for people."
  def results_label("always"), do: "Always"
  def results_label("voted"), do: "After voting"
  def results_label("closed"), do: "When the poll closes"
end
