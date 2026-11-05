defmodule Firefly.TrustLevelsPropertyTest do
  @moduledoc """
  Properties of `Firefly.TrustLevels`' review, against a model of its
  rules: for random activity (days visited, posts read, topics entered,
  likes given and received, topics replied to) and random thresholds, a
  review promotes a member to exactly the highest level whose
  requirements they meet, never demotes below their level unless they're
  a regular out of their grace period, leaves locked levels and leaders
  alone, and running it again changes nothing.
  """
  # Sync: it saves site settings (shared rows) and reviews every member.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Discussion, Repo, SiteSettings, TrustLevels}
  alias Firefly.Accounts.User

  @tl1 ~w(tl1_requires_topics_entered tl1_requires_read_posts)
  @tl2 ~w(tl2_requires_topics_entered tl2_requires_read_posts tl2_requires_days_visited
          tl2_requires_likes_received tl2_requires_likes_given tl2_requires_topic_reply_count)

  defp activity do
    fixed_map(%{
      days: integer(0..3),
      read: integer(0..6),
      entered: integer(0..3),
      given: integer(0..3),
      replied: integer(0..3),
      received: integer(0..3)
    })
  end

  defp thresholds do
    map(list_of(integer(0..4), length: length(@tl1 ++ @tl2)), &Enum.zip(@tl1 ++ @tl2, &1))
  end

  # The model: from level 0, level 1 if its requirements are met, then
  # level 2 if its own are too (each level is checked in turn); from level
  # 1, level 2 if its requirements are met. Never below `from`.
  defp expected(from, a, t) do
    tl1? =
      a.entered >= t["tl1_requires_topics_entered"] and a.read >= t["tl1_requires_read_posts"]

    tl2? =
      a.entered >= t["tl2_requires_topics_entered"] and a.read >= t["tl2_requires_read_posts"] and
        a.days >= t["tl2_requires_days_visited"] and
        a.received >= t["tl2_requires_likes_received"] and
        a.given >= t["tl2_requires_likes_given"] and
        a.replied >= t["tl2_requires_topic_reply_count"]

    case from do
      0 -> if tl1?, do: if(tl2?, do: 2, else: 1), else: 0
      1 -> if tl2?, do: 2, else: 1
      level -> level
    end
  end

  # Records the activity for `user`: threads by `other` (entered, liked,
  # replied to), likes on the user's replies, and visits.
  defp record(user, other, threads, a) do
    for thread <- Enum.take(threads, a.entered) do
      Repo.insert!(%Discussion.ThreadRead{
        user_id: user.id,
        thread_id: thread.id,
        last_read_post_id: 0
      })
    end

    for thread <- Enum.take(threads, a.given) do
      post = Repo.one!(from(p in Discussion.Post, where: p.thread_id == ^thread.id, limit: 1))
      Repo.insert!(%Discussion.PostLike{user_id: user.id, post_id: post.id})
    end

    replies =
      for thread <- Enum.take(threads, max(a.replied, a.received)) do
        # Inserted as it is: creating it would also mark the thread read.
        Repo.insert!(%Discussion.Post{
          thread_id: thread.id,
          user_id: user.id,
          body: "A reply here."
        })
      end

    # Likes received need replies to like; extra replies beyond `replied`
    # count as replied-to threads, so the model's `replied` is the count.
    for post <- Enum.take(replies, a.received) do
      Repo.insert!(%Discussion.PostLike{user_id: other.id, post_id: post.id})
    end

    for day <- 1..a.days//1 do
      read = if day == 1, do: a.read, else: 0

      Repo.insert_all("user_visits", [
        %{user_id: user.id, visited_on: Date.add(Date.utc_today(), -day), posts_read: read}
      ])
    end

    # Posts read are counted from visits: with no visit days, none.
    if a.days == 0 and a.read > 0 do
      Repo.insert_all("user_visits", [
        %{user_id: user.id, visited_on: Date.utc_today(), posts_read: a.read}
      ])
    end
  end

  test "review promotes to exactly the earned level, and only once" do
    admin = admin_fixture()
    other = user_fixture()
    category = category_fixture("Trust")

    threads =
      for n <- 1..3,
          do:
            thread_fixture(category, other, %{
              title: "Thread #{n} #{System.unique_integer([:positive])}"
            })

    check all(
            a <- activity(),
            t <- thresholds(),
            from <- integer(0..2),
            max_runs: runs(25)
          ) do
      {:ok, _} = SiteSettings.update(Map.new(t, fn {k, v} -> {k, to_string(v)} end), admin)
      t = Map.new(t)

      user = user_fixture(%{trust_level: from})
      record(user, other, threads, a)
      # Days visited counts visit rows: one more when reads were recorded today.
      a = if a.days == 0 and a.read > 0, do: %{a | days: 1}, else: a
      a = %{a | replied: max(a.replied, a.received)}

      TrustLevels.review()
      level = Repo.get!(User, user.id).trust_level
      assert level == expected(from, a, t), "from #{from} with #{inspect(a)} and #{inspect(t)}"

      # A second review changes nothing.
      TrustLevels.review()
      assert Repo.get!(User, user.id).trust_level == level
    end
  end

  test "regulars keep their level in the grace period, leaders and locked levels are left alone" do
    admin = admin_fixture()

    check all(
            level <- integer(0..4),
            lock? <- boolean(),
            days_ago <- integer(0..200),
            max_runs: runs(30)
          ) do
      user = user_fixture()
      {:ok, user} = TrustLevels.set_level(user, level, lock?, admin)
      changed = DateTime.add(DateTime.utc_now(:second), -days_ago * 86_400)
      Repo.update!(Ecto.Changeset.change(user, trust_level_changed_at: changed))

      TrustLevels.review()
      after_review = Repo.get!(User, user.id).trust_level
      grace = SiteSettings.get("tl3_promotion_min_duration")

      cond do
        lock? or level == 4 -> assert after_review == level
        # No activity: a regular out of grace goes back to member.
        level == 3 and days_ago >= grace -> assert after_review == 2
        level == 3 -> assert after_review == 3
        # Never demoted below where they are otherwise.
        true -> assert after_review >= level
      end
    end
  end

  property "progress/1 says what's needed, consistently with at_least?/2" do
    check all(level <- integer(0..4), max_runs: runs(20)) do
      user = user_fixture(%{trust_level: level})

      for l <- 0..4, do: assert(TrustLevels.at_least?(user, l) == level >= l)

      case TrustLevels.progress(user) do
        nil ->
          assert level == 4

        {next, requirements} ->
          assert next == min(level + 1, 3)
          assert Enum.all?(requirements, &(is_boolean(&1.met?) and is_integer(&1.have)))
      end
    end
  end
end
