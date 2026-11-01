defmodule FirestormWeb.Posting do
  @moduledoc """
  Whether a user may post right now (web, API and email): they must not be
  silenced or suspended (see `FirestormWeb.Penalties`), must have a
  confirmed email address (unless the `require_email_confirmation` site
  setting is off) and be within the posting rate limit, and a reply's
  thread must be open. Starting a private conversation also counts against
  the `:message` limit, so one account can't message crowds. Liking only
  checks penalties (`check(user, :like)`), as do other public writes that
  aren't posts (adding people to a conversation, editing a thread's title or
  tags, editing one's profile). Replying also needs the user to be able to
  read the thread (`:not_found` otherwise, as if it didn't exist): a
  reply-to address or API call outlives access to a category.
  """
  import Ecto.Query, only: [from: 2]

  alias FirestormWeb.{Penalties, RateLimit, Repo, SiteSettings}
  alias FirestormWeb.Forums.User

  def check(%User{} = user) do
    with :ok <- check(user, :like) do
      if confirmed_enough?(user), do: RateLimit.check_post(user), else: {:error, :unconfirmed}
    end
  end

  def check(%User{} = user, :like) do
    # Penalties are read from the database, not from `user`: an open page
    # holds the user as they were when it mounted, before any penalty.
    user = current_penalties(user)

    cond do
      User.suspended?(user) -> {:error, {:suspended, user.suspended_until}}
      User.silenced?(user) -> {:error, {:silenced, user.silenced_until}}
      true -> :ok
    end
  end

  def check(%User{} = user, :new_conversation) do
    with :ok <- check(user), do: RateLimit.check_message(user)
  end

  def check(%User{} = user, %FirestormWeb.Forums.Thread{id: thread_id} = thread) do
    cond do
      not Bodyguard.permit?(FirestormWeb.Forums, :view_thread, user, thread) ->
        {:error, :not_found}

      FirestormWeb.Forums.thread_closed?(thread_id) ->
        {:error, :closed}

      true ->
        check(user)
    end
  end

  @doc """
  Whether `user`'s email confirmation status lets them post: confirmed, or
  the site doesn't require it (the `require_email_confirmation` setting).
  """
  def confirmed_enough?(%User{} = user),
    do: User.confirmed?(user) or not SiteSettings.get("require_email_confirmation")

  defp current_penalties(%User{id: id} = user) do
    penalties =
      Repo.one(
        from(u in User,
          where: u.id == ^id,
          select: %{silenced_until: u.silenced_until, suspended_until: u.suspended_until}
        )
      )

    Map.merge(user, penalties || %{})
  end

  def message({:silenced, until}),
    do:
      "You've been silenced #{Penalties.ends_text(until)}: you can read, but not post, message or like."

  def message({:suspended, until}), do: "Your account is suspended #{Penalties.ends_text(until)}."

  def message(:closed), do: "This thread is closed to new replies."
  def message(:not_found), do: "Thread not found."
  def message(:unconfirmed), do: "Please confirm your email address before posting."
  def message(:rate_limited), do: RateLimit.message()
end
