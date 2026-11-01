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
  tags, editing one's profile); flagging checks penalties, a confirmed address
  and its own rate limit (`check(user, :flag)`). Replying also needs the user to be able to
  read the thread (`:not_found` otherwise, as if it didn't exist): a
  reply-to address or API call outlives access to a category. A thread in
  slow mode (see `FirestormWeb.TopicTools.set_slow_mode/3`) takes one reply
  per member per interval; admins are exempt.
  """
  import Ecto.Query, only: [from: 2]

  alias FirestormWeb.{Forums, Penalties, RateLimit, Repo, SiteSettings}
  alias FirestormWeb.Forums.{Post, Thread, User}

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

  # Flags can hide posts, so unlike posting this needs a confirmed address
  # whatever the `require_email_confirmation` setting says.
  def check(%User{} = user, :flag) do
    with :ok <- check(user, :like),
         :ok <- if(User.confirmed?(user), do: :ok, else: {:error, :unconfirmed}),
         do: RateLimit.check_flag(user)
  end

  def check(%User{} = user, :new_conversation) do
    with :ok <- check(user), do: RateLimit.check_message(user)
  end

  def check(%User{} = user, %Thread{id: thread_id} = thread) do
    cond do
      not Bodyguard.permit?(Forums, :view_thread, user, thread) ->
        {:error, :not_found}

      Forums.thread_closed?(thread_id) ->
        {:error, :closed}

      (wait = slow_mode_wait(user, thread_id)) > 0 ->
        {:error, {:slow_mode, wait}}

      true ->
        check(user)
    end
  end

  @doc """
  How many seconds `user` must still wait before replying in the thread
  with id `thread_id`, under its slow mode (0: they may reply now). Counts
  from their latest post there, deleted or not: deleting a reply doesn't
  buy another one sooner.
  """
  def slow_mode_wait(%User{} = user, thread_id) do
    # Read now, not from the caller's thread: an open page may predate it.
    seconds = Repo.one(from(t in Thread, where: t.id == ^thread_id, select: t.slow_mode_seconds))

    last_at =
      seconds &&
        Repo.one(
          from(p in Post,
            where: p.thread_id == ^thread_id and p.user_id == ^user.id,
            select: max(p.inserted_at)
          )
        )

    if is_nil(last_at) or Forums.admin?(user),
      do: 0,
      else: max(seconds - NaiveDateTime.diff(NaiveDateTime.utc_now(), last_at), 0)
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
      "You've been silenced #{Penalties.ends_text(until)}: you can read, but not post, message, like or flag."

  def message({:suspended, until}), do: "Your account is suspended #{Penalties.ends_text(until)}."

  def message(:closed), do: "This thread is closed to new replies."

  def message({:slow_mode, wait}),
    do: "This thread is in slow mode: you can reply again in #{duration_text(wait)}."

  def message(:not_found), do: "Thread not found."
  def message(:unconfirmed), do: "Please confirm your email address before posting."
  def message(:rate_limited), do: RateLimit.message()

  @doc ~S'A duration for people, in its two largest units: "45 seconds", "1 hour 5 minutes".'
  def duration_text(seconds) when seconds < 60, do: plural(seconds, "second")

  def duration_text(seconds) do
    # Rounded up to the minute: "in 2 minutes" must not undersell a wait.
    minutes = div(seconds + 59, 60)

    [
      {div(minutes, 1440), "day"},
      {div(rem(minutes, 1440), 60), "hour"},
      {rem(minutes, 60), "minute"}
    ]
    |> Enum.drop_while(&(elem(&1, 0) == 0))
    |> Enum.take(2)
    |> Enum.reject(&(elem(&1, 0) == 0))
    |> Enum.map_join(" ", fn {count, unit} -> plural(count, unit) end)
  end

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(count, unit), do: "#{count} #{unit}s"
end
