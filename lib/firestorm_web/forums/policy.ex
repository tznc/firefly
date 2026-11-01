defmodule FirestormWeb.Forums.Policy do
  @moduledoc """
  Authorization rules for the Forums context (see `Bodyguard.Policy`).

    * `:manage_category` (create, edit, delete) - admins
    * `:update_thread`, `:delete_thread` - the thread's author (unless it's
      archived) and admins
    * `:moderate_thread` (pin, close, archive, move) - admins
    * `:edit_post`, `:delete_post` (params `%{post: post, thread: thread}`) -
      the post's author while the thread is open, and admins; not once the
      post is deleted. (`Forums.delete_post/2` also refuses a thread's first
      post: delete the thread instead.)
    * `:restore_post`, `:view_deleted_posts` - admins
    * `:view_staff_log` - admins
    * `:like_post` (params `%{post: post, thread: thread}`) - members, on other
      people's posts that aren't deleted, unless the thread is archived
    * `:edit_user` - the user themselves
    * `:view_conversation` (a private conversation: read and reply) - its
      participants, until they leave. Nobody else, admins included.
    * `:add_participants` - participants who started the conversation, and
      admin participants
    * `:view_thread` - everyone, members or not (the one place to restrict
      who can read a thread, e.g. for private categories; notifications such
      as mentions check it). `readable_threads/2` is its query counterpart,
      for lists such as search results: keep the two in step.
  """

  @behaviour Bodyguard.Policy

  alias FirestormWeb.{Forums, Messages}
  alias FirestormWeb.Forums.{Conversation, Post, Thread, User}

  @impl true
  def authorize(:view_thread, _user, %Thread{}), do: :ok

  def authorize(_action, nil, _params), do: {:error, :unauthenticated}

  def authorize(:edit_user, %User{id: id}, %{user: %{id: id}}), do: :ok

  def authorize(:view_conversation, %User{} = user, %Conversation{} = conversation),
    do: if(Messages.participant?(conversation, user), do: :ok, else: {:error, :unauthorized})

  def authorize(:add_participants, %User{} = user, %Conversation{} = conversation) do
    cond do
      not Messages.participant?(conversation, user) -> {:error, :unauthorized}
      conversation.user_id == user.id -> :ok
      true -> admin(user)
    end
  end

  def authorize(:manage_category, %User{} = user, _params), do: admin(user)
  def authorize(:moderate_thread, %User{} = user, _params), do: admin(user)

  # Archived threads are read-only, except to admins.
  def authorize(action, %User{} = user, %Thread{} = thread)
      when action in [:update_thread, :delete_thread] do
    if Forums.thread_author_id(thread) == user.id and not Thread.archived?(thread),
      do: :ok,
      else: admin(user)
  end

  def authorize(action, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread})
      when action in [:edit_post, :delete_post] do
    cond do
      Post.deleted?(post) -> {:error, :unauthorized}
      post.user_id == user.id and not Thread.closed?(thread) -> :ok
      true -> admin(user)
    end
  end

  def authorize(:like_post, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread}) do
    if post.user_id != user.id and not Post.deleted?(post) and not Thread.archived?(thread),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def authorize(action, %User{} = user, _params)
      when action in [:restore_post, :view_deleted_posts, :view_staff_log],
      do: admin(user)

  # Catch-all: deny everything else
  def authorize(_action, _user, _params), do: {:error, :unauthorized}

  defp admin(user), do: if(Forums.admin?(user), do: :ok, else: {:error, :unauthorized})

  @doc """
  Restricts `query` to threads `user` (or nil, a visitor) may read, as the
  `:view_thread` rule does for one thread. The query must bind the thread
  as `:thread`. Everyone may read every thread for now.
  """
  def readable_threads(query, _user), do: query
end
