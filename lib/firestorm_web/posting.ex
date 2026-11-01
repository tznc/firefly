defmodule FirestormWeb.Posting do
  @moduledoc """
  Whether a user may post right now (web, API and email): they must not be
  silenced or suspended (see `FirestormWeb.Penalties`), must have a
  confirmed email address and be within the posting rate limit, and a reply's
  thread must be open. Starting a private conversation also counts against
  the `:message` limit, so one account can't message crowds. Liking only
  checks penalties (`check(user, :like)`); flagging checks penalties and its
  own rate limit (`check(user, :flag)`). Replying also needs the user to
  be able to read the thread (`:not_found` otherwise, as if it didn't
  exist): a reply-to address or API call outlives access to a category.
  """
  alias FirestormWeb.{Penalties, RateLimit}
  alias FirestormWeb.Forums.User

  def check(%User{} = user) do
    with :ok <- check(user, :like) do
      if User.confirmed?(user), do: RateLimit.check_post(user), else: {:error, :unconfirmed}
    end
  end

  def check(%User{} = user, :like) do
    cond do
      User.suspended?(user) -> {:error, {:suspended, user.suspended_until}}
      User.silenced?(user) -> {:error, {:silenced, user.silenced_until}}
      true -> :ok
    end
  end

  def check(%User{} = user, :flag) do
    with :ok <- check(user, :like), do: RateLimit.check_flag(user)
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

  def message({:silenced, until}),
    do:
      "You've been silenced #{Penalties.ends_text(until)}: you can read, but not post, message, like or flag."

  def message({:suspended, until}), do: "Your account is suspended #{Penalties.ends_text(until)}."

  def message(:closed), do: "This thread is closed to new replies."
  def message(:not_found), do: "Thread not found."
  def message(:unconfirmed), do: "Please confirm your email address before posting."
  def message(:rate_limited), do: RateLimit.message()
end
