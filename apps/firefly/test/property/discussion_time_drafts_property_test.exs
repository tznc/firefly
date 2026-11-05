defmodule Firefly.DiscussionTimeDraftsPropertyTest do
  @moduledoc """
  Properties of times people pick in their own time zone
  (`Firefly.LocalTime`, bookmark reminders) and of composer drafts:
  datetime-local values round-trip through UTC for any browser offset;
  "tomorrow" and "next week" reminders fall at 8am local, in the future,
  on the right day; and saving a draft with any title, tags and body is
  saved, discarded or refused, never a crash.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.LocalTime
  alias Firefly.Discussion.{Bookmarks, Drafts}

  # Browser offsets as FireflyWeb.LocalTime accepts them: +-14 hours.
  defp offset, do: integer((-14 * 60)..(14 * 60))

  defp moment do
    map(integer(1_600_000_000..2_000_000_000), &DateTime.from_unix!/1)
  end

  property "datetime-local values round-trip through UTC" do
    check all(at <- moment(), offset <- offset(), max_runs: runs(500)) do
      input = LocalTime.to_input(at, offset)
      assert {:ok, parsed} = LocalTime.parse(input, offset)
      # The input has minutes, not seconds.
      assert DateTime.diff(at, parsed) in 0..59
      assert LocalTime.to_input(parsed, offset) == input
    end
  end

  property "parsing any text is a time, blank or an error" do
    check all(
            input <- one_of([any_text(), adversarial_text()]),
            offset <- offset(),
            max_runs: runs(300)
          ) do
      assert match?({:ok, %DateTime{}}, LocalTime.parse(input, offset)) or
               LocalTime.parse(input, offset) in [:blank, :error]
    end
  end

  property "reminders fall at 8am local, in the future, on the right day" do
    check all(now <- moment(), offset <- offset(), max_runs: runs(500)) do
      today = LocalTime.to_date(now, offset)

      tomorrow = Bookmarks.remind_at("tomorrow", nil, offset, now)
      assert DateTime.after?(tomorrow, now)
      assert LocalTime.to_date(tomorrow, offset) == Date.add(today, 1)
      assert String.ends_with?(LocalTime.to_input(tomorrow, offset), "T08:00")

      next_week = Bookmarks.remind_at("next_week", nil, offset, now)
      assert DateTime.after?(next_week, now)
      assert Date.day_of_week(LocalTime.to_date(next_week, offset)) == 1
      assert Date.diff(LocalTime.to_date(next_week, offset), today) in 1..7
      assert String.ends_with?(LocalTime.to_input(next_week, offset), "T08:00")

      assert Bookmarks.remind_at("later_today", nil, offset, now) == DateTime.add(now, 3, :hour)
      assert Bookmarks.remind_at("whenever", nil, offset, now) == nil
    end
  end

  property "saving a draft with any content is saved, discarded or refused" do
    user = user_fixture()
    category = category_fixture("Drafts #{System.unique_integer([:positive])}")

    check all(
            title <- one_of([adversarial_text(), zalgo(), long_string(400), constant("")]),
            tags <- one_of([adversarial_text(4), zalgo(), constant(nil)]),
            body <- one_of([adversarial_text(), constant(""), long_string(2_000)]),
            max_runs: runs(100)
          ) do
      attrs =
        for {k, v} <- %{"title" => title, "tags" => tags, "body" => body},
            into: %{},
            do: {k, v && String.replace(v, <<0>>, "")}

      case Drafts.save(user, {:new_thread, category}, attrs) do
        {:ok, nil} -> assert Drafts.get(user, {:new_thread, category}) == nil
        {:ok, draft} -> assert Drafts.get(user, {:new_thread, category}).id == draft.id
        {:error, %Ecto.Changeset{}} -> :ok
        {:error, :too_many} -> flunk("one draft can't be too many")
      end
    end
  end
end
