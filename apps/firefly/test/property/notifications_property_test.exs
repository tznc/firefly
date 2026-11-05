defmodule Firefly.NotificationsPropertyTest do
  @moduledoc """
  Properties of `Firefly.Notifications`: for any levels a member sets on a
  thread, its category, the category's parent and its tags, the
  one-thread rule (`effective_thread_level/2`), the muted-threads query
  the lists use and the subscribers notified of new posts all agree with
  a model of the documented precedence; and unread counts are exactly the
  unread notifications, whatever is marked read.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Discussion, Notifications}
  alias Firefly.Discussion.Tag
  alias Firefly.Notifications.Subscriptions

  defp level, do: one_of([constant(nil), member_of(Subscriptions.levels())])

  # The model (the moduledoc): the thread's own level, else the category's
  # (or, unset, its parent's) combined with the tags': muted wins, then the
  # most attentive, else normal.
  defp expected(levels) do
    category = levels.category || levels.parent
    inherited = Enum.reject([category | levels.tags], &is_nil/1)

    levels.thread ||
      cond do
        "muted" in inherited -> "muted"
        "watching" in inherited -> "watching"
        "tracking" in inherited -> "tracking"
        true -> "normal"
      end
  end

  test "the thread's level, the muted list and the subscribers agree with the model" do
    author = user_fixture()

    {:ok, parent} =
      Discussion.create_category(%{title: "Parent #{System.unique_integer([:positive])}"})

    {:ok, category} =
      Discussion.create_category(%{
        title: "Child #{System.unique_integer([:positive])}",
        parent_id: parent.id
      })

    {:ok, thread} =
      Discussion.create_thread(category, author, %{
        title: "Levels here",
        body: "Hello.",
        tags: "alpha, beta"
      })

    tags = Repo.all(from(t in Tag, where: t.name in ["alpha", "beta"], order_by: t.name))

    check all(
            levels <-
              fixed_map(%{
                thread: level(),
                category: level(),
                parent: level(),
                tags: list_of(level(), length: 2)
              }),
            max_runs: runs(150)
          ) do
      user = user_fixture()
      if levels.thread, do: {:ok, _} = Subscriptions.set_thread_level(user, thread, levels.thread)

      if levels.category,
        do: {:ok, _} = Subscriptions.set_category_level(user, category, levels.category)

      if levels.parent,
        do: {:ok, _} = Subscriptions.set_category_level(user, parent, levels.parent)

      for {tag, tag_level} <- Enum.zip(tags, levels.tags),
          tag_level,
          do: {:ok, _} = Subscriptions.set_tag_level(user, tag, tag_level)

      level = expected(levels)
      assert Subscriptions.effective_thread_level(user, thread) == level, inspect(levels)

      muted? = thread.id in Repo.all(Subscriptions.muted_thread_ids(user))
      assert muted? == (level == "muted"), "muted list for #{inspect(levels)}"

      subscribed = for {u, l} <- Subscriptions.subscribers(thread), u.id == user.id, do: l

      assert subscribed == if(level in ~w(watching tracking), do: [level], else: []),
             "subscribers for #{inspect(levels)}"
    end
  end

  property "unread counts are exactly the unread notifications" do
    check all(
            subjects <-
              list_of(map(adversarial_text(4), &String.replace(&1, <<0>>, "")),
                min_length: 1,
                max_length: 6
              ),
            reads <- list_of(integer(0..5), max_length: 4),
            all? <- boolean(),
            max_runs: runs(40)
          ) do
      user = user_fixture()

      for subject <- subjects do
        {:ok, _} =
          Notifications.notify(user, %{
            kind: "plugin",
            subject: "S " <> subject,
            body: "B " <> subject,
            url: "/"
          })
      end

      notifications = Notifications.notifications_for(user)
      assert length(notifications) == length(subjects)

      for i <- reads,
          notification = Enum.at(notifications, i),
          do: Notifications.mark_notification_read(notification)

      if all?, do: Notifications.mark_all_notifications_read(user)

      unread = user |> Notifications.notifications_for() |> Enum.count(&is_nil(&1.read_at))
      assert Notifications.unread_notification_count(user) == unread

      assert unread ==
               if(all?,
                 do: 0,
                 else:
                   length(subjects) -
                     length(Enum.uniq(Enum.filter(reads, &(&1 < length(subjects)))))
               )
    end
  end
end
