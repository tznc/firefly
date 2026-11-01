defmodule FirestormWeb.Posting do
  @moduledoc """
  Whether a user may post right now (web, API and email): they must have a
  confirmed email address and be within the posting rate limit, and a reply's
  thread must be open. Starting a private conversation also counts against
  the `:message` limit, so one account can't message crowds.
  """
  alias FirestormWeb.RateLimit
  alias FirestormWeb.Forums.User

  def check(%User{} = user) do
    if User.confirmed?(user), do: RateLimit.check_post(user), else: {:error, :unconfirmed}
  end

  def check(%User{} = user, :new_conversation) do
    with :ok <- check(user), do: RateLimit.check_message(user)
  end

  def check(%User{} = user, %FirestormWeb.Forums.Thread{id: thread_id}) do
    if FirestormWeb.Forums.thread_closed?(thread_id), do: {:error, :closed}, else: check(user)
  end

  def message(:closed), do: "This thread is closed to new replies."
  def message(:unconfirmed), do: "Please confirm your email address before posting."
  def message(:rate_limited), do: RateLimit.message()
end
