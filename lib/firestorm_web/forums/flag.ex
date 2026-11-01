defmodule FirestormWeb.Forums.Flag do
  @moduledoc """
  A member's flag on a post: a `reason` (`"spam"`, `"inappropriate"`,
  `"off_topic"` or `"other"`, which needs a `note`) and a review `status`:
  `"pending"` until staff decide, then `"agreed"`, `"disagreed"` or
  `"deferred"`. One per user per post. See `FirestormWeb.Flags`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{Post, User}

  @reasons ~w(spam inappropriate off_topic other)
  @statuses ~w(pending agreed disagreed deferred)

  schema "forums_post_flags" do
    field(:reason, :string)
    field(:note, :string)
    field(:status, :string, default: "pending")
    field(:reviewed_at, :utc_datetime)
    belongs_to(:post, Post)
    belongs_to(:user, User)
    belongs_to(:reviewed_by, User)

    timestamps(type: :naive_datetime_usec)
  end

  def reasons, do: @reasons
  def statuses, do: @statuses

  @doc "The reason as members read it."
  def reason_label("spam"), do: "Spam"
  def reason_label("inappropriate"), do: "Inappropriate"
  def reason_label("off_topic"), do: "Off-topic"
  def reason_label("other"), do: "Something else"

  def changeset(%__MODULE__{} = flag, attrs) do
    flag
    |> cast(attrs, [:reason, :note])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_length(:note, max: 1000)
    |> validate_note()
    |> unique_constraint([:post_id, :user_id], message: "you already flagged this post")
  end

  # "Something else" must say what.
  defp validate_note(changeset) do
    if get_field(changeset, :reason) == "other",
      do: validate_required(changeset, :note, message: "say what's wrong"),
      else: changeset
  end
end
