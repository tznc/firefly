defmodule FirestormWeb.Posting do
  @moduledoc """
  Whether a user may post right now (web, API and email): they must have a
  confirmed email address and be within the posting rate limit.
  """
  alias FirestormWeb.RateLimit
  alias FirestormWeb.Forums.User

  @spec check(User.t()) :: :ok | {:error, :unconfirmed | :rate_limited}
  def check(%User{} = user) do
    if User.confirmed?(user), do: RateLimit.check_post(user), else: {:error, :unconfirmed}
  end

  def message(:unconfirmed), do: "Please confirm your email address before posting."
  def message(:rate_limited), do: RateLimit.message()
end
