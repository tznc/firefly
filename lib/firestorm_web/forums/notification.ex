defmodule FirestormWeb.Forums.Notification do
  @moduledoc """
  An in-app notification. `kind` is `"new_thread"` (a thread started in a
  category you watch or track), `"new_post"` (a reply in a thread you watch
  or track), `"mentioned"` (someone @mentioned you in a post) or `"liked"`
  (someone liked your post; never emailed). `read_at` is set when you open it
  or read the thread; `emailed_at` when it was also sent by email.
  """

  use Ecto.Schema
  alias FirestormWeb.Forums.{User, Thread, Post}
  import Ecto.Changeset

  @kinds ~w(new_thread new_post mentioned liked)

  schema "forums_notifications" do
    field(:kind, :string, default: "new_post")
    field(:body, :string)
    field(:subject, :string)
    field(:url, :string)
    field(:read_at, :utc_datetime)
    field(:emailed_at, :utc_datetime)
    belongs_to(:user, User)
    belongs_to(:thread, Thread)
    belongs_to(:post, Post)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "Notification attributes for a new thread, a reply or a mention in a post."
  def for_post(kind, %Thread{} = thread, %Post{} = post, %User{} = author)
      when kind in ~w(new_thread new_post mentioned) do
    subject =
      case kind do
        "new_thread" -> "@#{author.username} started \"#{thread.title}\""
        "new_post" -> "@#{author.username} replied in \"#{thread.title}\""
        "mentioned" -> "@#{author.username} mentioned you in \"#{thread.title}\""
      end

    %{
      kind: kind,
      subject: subject,
      body: post.body,
      url: "#{FirestormWeb.Web.Paths.thread_url(thread)}#post-#{post.id}",
      thread_id: thread.id,
      post_id: post.id
    }
  end

  @doc """
  Notification attributes for likes on `post`: `likers` are the users who
  liked it, most recent first (one notification covers them all).
  """
  def for_likes(%Thread{} = thread, %Post{} = post, [latest | others]) do
    who =
      case length(others) do
        0 -> "@#{latest.username}"
        1 -> "@#{latest.username} and 1 other"
        n -> "@#{latest.username} and #{n} others"
      end

    %{
      kind: "liked",
      subject: "#{who} liked your post in \"#{thread.title}\"",
      body: post.body,
      url: "#{FirestormWeb.Web.Paths.thread_url(thread)}#post-#{post.id}",
      thread_id: thread.id,
      post_id: post.id
    }
  end

  # Kept for callers that predate typed notifications.
  def thread_new_post_notification(%Thread{} = thread, %Post{} = post) do
    %{
      subject: "There was a new post in thread: #{thread.title}",
      body: post.body,
      url: "#{FirestormWeb.Web.Paths.thread_url(thread)}#post-#{post.id}"
    }
  end

  def read?(%__MODULE__{read_at: read_at}), do: not is_nil(read_at)

  @doc "The in-app path to open (the url's path and fragment)."
  def path(%__MODULE__{url: url}) do
    uri = URI.parse(url || "/")
    (uri.path || "/") <> if(uri.fragment, do: "#" <> uri.fragment, else: "")
  end

  def changeset(%__MODULE__{} = notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :kind, :body, :subject, :url, :thread_id, :post_id])
    |> validate_required([:user_id, :body, :subject, :url])
    |> validate_inclusion(:kind, @kinds)
  end
end
