defmodule Firefly.Accounts.Visits do
  @moduledoc """
  Minimal visit tracking, for the user directory (see
  `Firefly.Directory`) and profiles: a user's `last_seen_at`, and one
  `user_visits` row per day they came, counting the posts they read that
  day.

  `seen/1` runs when a logged-in page connects; to keep that cheap it only
  writes when `last_seen_at` is more than a minute old, and adds the day's
  visit only when that's the first time today.
  """

  import Ecto.Query

  alias Firefly.Repo
  alias Firefly.Accounts.User

  @fresh_seconds 60

  @doc "Records that `user` is on the site now."
  def seen(%User{last_seen_at: last} = user) do
    now = DateTime.utc_now(:second)

    # Nothing is written while the site is read-only (see Firefly.Backups).
    if (is_nil(last) or DateTime.diff(now, last) > @fresh_seconds) and
         not Firefly.Backups.read_only?() do
      User |> where([u], u.id == ^user.id) |> Repo.update_all(set: [last_seen_at: now])

      if is_nil(last) or DateTime.to_date(last) != DateTime.to_date(now),
        do: add_visit(user.id, DateTime.to_date(now), 0)
    end

    :ok
  end

  def seen(nil), do: :ok

  @doc "Adds `count` posts to what the user with id `user_id` read today."
  def read_posts(_user_id, 0), do: :ok

  def read_posts(user_id, count) when count > 0 do
    add_visit(user_id, Date.utc_today(), count)
    :ok
  end

  defp add_visit(user_id, date, posts_read) do
    Repo.insert_all(
      "user_visits",
      [%{user_id: user_id, visited_on: date, posts_read: posts_read}],
      on_conflict: [inc: [posts_read: posts_read]],
      conflict_target: [:user_id, :visited_on]
    )
  end
end
