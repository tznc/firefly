defmodule FirestormWeb.Forums.Post do
  @moduledoc """
  Schema for forum posts.
  """

  use Ecto.Schema
  import Ecto.Changeset, warn: false
  import Ecto.Query
  alias FirestormWeb.Forums.{Flag, Poll, User, Thread, View}

  schema "forums_posts" do
    field(:body, :string)
    field(:edited_at, :naive_datetime_usec)
    field(:deleted_at, :utc_datetime)
    field(:hidden_at, :utc_datetime)
    field(:queued_at, :utc_datetime)
    # Set when a plugin's moderation hook queued it (see FirestormWeb.Plugins.Moderation).
    field(:queued_reason, :string)
    # A wiki post: anyone who may post in its thread may edit it (see the
    # `:edit_post` policy). Set by staff (`Forums.set_wiki/3`).
    field(:wiki, :boolean, default: false)
    belongs_to(:deleted_by, User)
    belongs_to(:thread, Thread)
    belongs_to(:user, User)
    has_many(:flags, Flag)
    # Created with the post, in the composer (see `FirestormWeb.Polls`).
    has_one(:poll, Poll)
    has_many(:views, {"forums_posts_views", View}, foreign_key: :assoc_id)

    many_to_many(
      :viewers,
      User,
      join_through: "forums_posts_views",
      join_keys: [assoc_id: :id, user_id: :id]
    )

    field(:oembeds, :any, virtual: true)
    # Set by FirestormWeb.LinkPreviews.decorate/1.
    field(:link_previews, :any, virtual: true, default: [])

    timestamps(type: :naive_datetime_usec)
  end

  # Discourse's default: long enough for any real post, short enough that
  # one can't fill pages (or a draft, see FirestormWeb.Drafts) with junk.
  @max_body_length 32_000

  @doc "The longest a post body (or a draft's) may be, in characters."
  def max_body_length, do: @max_body_length

  def changeset(%__MODULE__{} = post, attrs \\ %{}) do
    post
    |> cast(attrs, [:body, :thread_id, :user_id])
    |> validate_required([:body, :thread_id, :user_id])
    |> validate_body_length()
    |> cast_poll(attrs)
  end

  @doc "Adds the poll in `attrs`' `:poll`, if any, to a new post's changeset."
  def cast_poll(changeset, attrs) do
    if Map.has_key?(attrs, :poll),
      do: cast_assoc(changeset, :poll, with: &Poll.changeset/2),
      else: changeset
  end

  @doc "An edit of the body by its author or an admin."
  def edit_changeset(%__MODULE__{} = post, attrs) do
    post
    |> cast(attrs, [:body])
    |> validate_required([:body])
    |> validate_body_length()
  end

  @doc "Validates that the changeset's `:body` fits `max_body_length/0`."
  def validate_body_length(changeset),
    do: validate_length(changeset, :body, max: @max_body_length)

  @doc "Whether the post is a wiki: editable by anyone who may post in its thread."
  def wiki?(%__MODULE__{wiki: wiki}), do: wiki == true

  @doc "Whether the post was (soft) deleted. Its content is then hidden from members."
  def deleted?(%__MODULE__{deleted_at: at}), do: not is_nil(at)

  @doc """
  Whether the post is hidden pending review, after enough flags (see
  `FirestormWeb.Flags`). Only its author and admins see its content.
  """
  def hidden?(%__MODULE__{hidden_at: at}), do: not is_nil(at)

  @doc """
  Whether the post waits for staff approval (see `FirestormWeb.Review`).
  Until then only its author and admins see it.
  """
  def queued?(%__MODULE__{queued_at: at}), do: not is_nil(at)

  @doc """
  Whether `user` (nil: a visitor) may read the post's content: anyone, once
  it's published; a deleted post, admins only; one hidden after flags or
  awaiting approval, its author and admins. Every way of reading a single
  post by id (pages, quotes, history, the API and channels) goes through
  this, so they stay in step. With nil it's whether the post is public.
  """
  def readable_by?(%__MODULE__{} = post, user) do
    cond do
      deleted?(post) -> permit?(:view_deleted_posts, user, post)
      hidden?(post) or queued?(post) -> permit?(:view_hidden_post, user, post)
      true -> true
    end
  end

  defp permit?(action, user, post),
    do: Bodyguard.permit?(FirestormWeb.Forums, action, user, post)

  @doc "Posts that are published: not deleted or awaiting approval."
  def visible(query \\ __MODULE__),
    do: where(query, [p], is_nil(p.deleted_at) and is_nil(p.queued_at))

  def ordered(query) do
    query
    |> order_by([p], desc: p.inserted_at)
  end
end
