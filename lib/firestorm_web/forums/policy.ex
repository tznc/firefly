defmodule FirestormWeb.Forums.Policy do
  @moduledoc """
  Authorization rules for the Forums context (see `Bodyguard.Policy`).

    * `:manage_category` (create, edit, delete) - admins
    * `:update_thread`, `:delete_thread` - the thread's author (unless it's
      archived) and admins
    * `:moderate_thread` (pin, close, archive, move) - admins
    * `:edit_user` - the user themselves
  """

  @behaviour Bodyguard.Policy

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Thread, User}

  @impl true
  def authorize(_action, nil, _params), do: {:error, :unauthenticated}

  def authorize(:edit_user, %User{id: id}, %{user: %{id: id}}), do: :ok

  def authorize(:manage_category, %User{} = user, _params), do: admin(user)
  def authorize(:moderate_thread, %User{} = user, _params), do: admin(user)

  # Archived threads are read-only, except to admins.
  def authorize(action, %User{} = user, %Thread{} = thread)
      when action in [:update_thread, :delete_thread] do
    if Forums.thread_author_id(thread) == user.id and not Thread.archived?(thread),
      do: :ok,
      else: admin(user)
  end

  # Catch-all: deny everything else
  def authorize(_action, _user, _params), do: {:error, :unauthorized}

  defp admin(user), do: if(Forums.admin?(user), do: :ok, else: {:error, :unauthorized})
end
