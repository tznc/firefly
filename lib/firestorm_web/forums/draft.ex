defmodule FirestormWeb.Forums.Draft do
  @moduledoc """
  A user's unsent composer content (see `FirestormWeb.Drafts`). `kind` is
  `"new_thread"` (with `category_id`), `"reply"` (with `thread_id`) or
  `"edit"` (with `post_id`); `key` names that composer, one draft each.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{Category, Post, Thread, User}

  schema "forums_drafts" do
    field(:key, :string)
    field(:kind, :string)
    field(:title, :string)
    field(:tags, :string)
    field(:body, :string)
    belongs_to(:user, User)
    belongs_to(:category, Category)
    belongs_to(:thread, Thread)
    belongs_to(:post, Post)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = draft, attrs) do
    draft
    |> cast(attrs, [:title, :tags, :body])
    |> validate_length(:title, max: 255)
    |> validate_length(:tags, max: 255)
    |> Post.validate_body_length()
  end

  @doc "Whether the draft holds nothing worth keeping."
  def blank?(%__MODULE__{} = draft),
    do: Enum.all?([draft.title, draft.tags, draft.body], &(String.trim(&1 || "") == ""))
end
