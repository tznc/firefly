defmodule FirestormWeb.Forums.Notification do
  @moduledoc """
  Schema for notifications.
  """

  use Ecto.Schema
  alias FirestormWeb.Forums.{User, Thread, Post}
  import Ecto.Changeset

  schema "forums_notifications" do
    field(:body, :string)
    field(:subject, :string)
    field(:url, :string)
    belongs_to(:user, User)

    timestamps(type: :naive_datetime_usec)
  end

  def thread_new_post_notification(%Thread{} = thread, %Post{} = post) do
    %{
      subject: "There was a new post in thread: #{thread.title}",
      body: post.body,
      url: post_url(thread, post)
    }
  end

  defp post_url(thread, post) do
    "#{thread_url(thread)}#post-#{post.id}"
  end

  defp thread_url(thread) do
    FirestormWeb.Web.Paths.thread_url(thread)
  end

  def changeset(%__MODULE__{} = notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :body, :subject, :url])
    |> validate_required([:user_id, :body, :subject, :url])
  end
end
