defmodule FirestormWeb.Forums.Policy do
  @moduledoc """
  Authorization rules for the Forums context (see `Bodyguard.Policy`).

    * `:manage_category` (create, edit, delete) - admins
    * `:update_thread`, `:delete_thread` - the thread's author and admins
    * `:moderate_thread` (pin, close, archive, move) - admins
    * `:edit_post`, `:delete_post` (params `%{post: post, thread: thread}`) -
      the post's author while the thread is open, and admins; not once the
      post is deleted. (`Forums.delete_post/2` also refuses a thread's first
      post: delete the thread instead.)
    * `:restore_post`, `:view_deleted_posts` - admins
    * `:edit_user` - the user themselves
  """

  @behaviour Bodyguard.Policy

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Post, Thread, User}

  @impl true
  def authorize(_action, nil, _params), do: {:error, :unauthenticated}

  def authorize(:edit_user, %User{id: id}, %{user: %{id: id}}), do: :ok

  def authorize(:manage_category, %User{} = user, _params), do: admin(user)
  def authorize(:moderate_thread, %User{} = user, _params), do: admin(user)

  def authorize(action, %User{} = user, %Thread{} = thread)
      when action in [:update_thread, :delete_thread] do
    if Forums.thread_author_id(thread) == user.id, do: :ok, else: admin(user)
  end

  def authorize(action, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread})
      when action in [:edit_post, :delete_post] do
    cond do
      Post.deleted?(post) -> {:error, :unauthorized}
      post.user_id == user.id and not Thread.closed?(thread) -> :ok
      true -> admin(user)
    end
  end

  def authorize(action, %User{} = user, _params)
      when action in [:restore_post, :view_deleted_posts],
      do: admin(user)

  # Catch-all: deny everything else
  def authorize(_action, _user, _params), do: {:error, :unauthorized}

  defp admin(user), do: if(Forums.admin?(user), do: :ok, else: {:error, :unauthorized})
end
