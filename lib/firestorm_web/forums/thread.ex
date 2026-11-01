defmodule FirestormWeb.Forums.Thread do
  @moduledoc """
  Schema for forum threads.
  """

  use Ecto.Schema
  import Ecto.Changeset, warn: false

  alias FirestormWeb.Forums.{Category, Post, Tag, Watch, User}
  alias FirestormWeb.Forums.Slugs.ThreadTitleSlug

  schema "forums_threads" do
    field(:title, :string)
    field(:slug, ThreadTitleSlug.Type)
    field(:first_post, :any, virtual: true)
    field(:posts_count, :integer, virtual: true)
    field(:completely_read?, :boolean, virtual: true)
    field(:unread_count, :integer, virtual: true)
    field(:first_unread_post_id, :integer, virtual: true)
    field(:new?, :boolean, virtual: true)
    field(:last_post_at, :naive_datetime_usec, virtual: true)
    field(:pinned_at, :utc_datetime)
    field(:closed_at, :utc_datetime)
    field(:archived_at, :utc_datetime)
    belongs_to(:category, Category)
    # Explicit order: an edited post's row moves in the table, so the
    # database's natural order isn't the posting order.
    has_many(:posts, Post, preload_order: [asc: :inserted_at, asc: :id])

    many_to_many(:tags, Tag,
      join_through: "forums_threads_tags",
      on_replace: :delete,
      preload_order: [asc: :name]
    )

    has_many(:watches, {"forums_threads_watches", Watch}, foreign_key: :assoc_id)

    many_to_many(
      :watchers,
      User,
      join_through: "forums_threads_watches",
      join_keys: [assoc_id: :id, user_id: :id]
    )

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = thread, attrs \\ %{}) do
    thread
    |> cast(attrs, [:title, :category_id])
    |> validate_required([:title, :category_id])
    |> ThreadTitleSlug.maybe_generate_slug()
    |> ThreadTitleSlug.unique_constraint()
  end

  @doc "Moderation changes: pin, close, archive, move to another category."
  def moderation_changeset(%__MODULE__{} = thread, attrs) do
    thread
    |> cast(attrs, [:pinned_at, :closed_at, :archived_at, :category_id])
    |> validate_required([:category_id])
    |> foreign_key_constraint(:category_id)
  end

  def pinned?(%__MODULE__{pinned_at: at}), do: not is_nil(at)
  def archived?(%__MODULE__{archived_at: at}), do: not is_nil(at)

  @doc "Closed threads take no new replies. Archived threads are closed too."
  def closed?(%__MODULE__{} = thread), do: not is_nil(thread.closed_at) or archived?(thread)

  def new_changeset(%{thread: thread_attrs, post: post_attrs}, user \\ nil) do
    post_changeset =
      %Post{}
      |> cast(post_attrs, [:body, :user_id])
      |> validate_required([:body, :user_id])

    post_changeset =
      if user,
        do: FirestormWeb.Forums.SpamGuard.validate_post(post_changeset, user),
        else: post_changeset

    %__MODULE__{}
    |> changeset(thread_attrs)
    |> put_assoc(:posts, [post_changeset])
  end
end
