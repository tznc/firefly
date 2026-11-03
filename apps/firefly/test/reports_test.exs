defmodule Firefly.ReportsTest do
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.{Discussion, Repo, Reports}
  alias Firefly.Discussion.Thread

  setup do
    author = user_fixture()
    replier = user_fixture()
    category = category_fixture()
    answered = thread_fixture(category, author, %{title: "Answered"})
    _lonely = thread_fixture(category, author, %{title: "Lonely"})
    {:ok, _post} = Discussion.create_post(answered, replier, %{body: "Here's how"})
    {:ok, author: author, replier: replier, answered: answered}
  end

  defp total(id, range \\ Reports.last(7)) do
    %{result: result} = Reports.run(Reports.get(id), range)
    result |> Reports.totals() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  end

  test "every report runs, with a unique id" do
    ids = Enum.map(Reports.list(), & &1.id())
    assert length(ids) == 23
    assert ids == Enum.uniq(ids)

    for report <- Reports.list() do
      assert %{result: result} = Reports.run(report, Reports.last(30))
      assert match?({:series, [_ | _]}, result) or match?({:table, [_ | _], _}, result)
      assert is_binary(Reports.to_csv(result))
    end
  end

  test "daily series count per day, with every day of the range" do
    assert total("signups") == 2
    assert total("topics") == 2
    assert total("posts") == 3

    %{result: {:series, [%{points: points}]}} =
      Reports.run(Reports.get("topics"), Reports.last(7))

    assert length(points) == 7
    assert List.last(points) == {Date.utc_today(), 2}

    # Nothing before today.
    yesterday = Date.add(Date.utc_today(), -1)
    assert total("topics", %{from: Date.add(yesterday, -6), to: yesterday}) == 0
  end

  test "topics with no response and time to first response", ctx do
    %{result: {:table, _columns, rows}} =
      Reports.run(Reports.get("topics_without_response"), Reports.last(7))

    assert [["Lonely", "Elixir", _date]] = rows

    # A reply an hour after the topic was started.
    Repo.update_all(from(t in Thread, where: t.id == ^ctx.answered.id),
      set: [inserted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)]
    )

    %{result: {:series, [%{points: points}]}} =
      Reports.run(Reports.get("time_to_first_response"), Reports.last(7))

    assert {_today, hours} = List.last(points)
    assert_in_delta hours, 1.0, 0.1
  end

  test "the overview compares with the previous period" do
    %{result: metrics} = Reports.overview(Reports.last(7))
    by_key = Map.new(metrics, &{&1.key, &1})

    assert %{value: 2, previous: 0} = by_key["topics"]
    assert %{value: 50, previous: nil} = by_key["response_rate"]
    assert %{value: 0, previous: nil} = by_key["review_queue"]
    assert %{format: :bytes} = by_key["storage"]
  end

  test "ranges: presets, custom and the previous period" do
    today = Date.utc_today()
    assert Reports.range(%{"period" => "90"}) == %{from: Date.add(today, -89), to: today}
    assert Reports.range(%{"period" => "13"}) == Reports.last(30)

    assert Reports.range(%{"from" => "2026-01-01", "to" => "2026-01-31"}) ==
             %{from: ~D[2026-01-01], to: ~D[2026-01-31]}

    # Backwards: the default.
    assert Reports.range(%{"from" => "2026-02-01", "to" => "2026-01-01"}) == Reports.last(30)

    assert Reports.previous(%{from: ~D[2026-01-11], to: ~D[2026-01-20]}) ==
             %{from: ~D[2026-01-01], to: ~D[2026-01-10]}
  end

  test "CSV export quotes cells and defuses formulas" do
    csv = Reports.to_csv({:table, ["Name", "Count"], [["a, b", 1], ["=HYPERLINK()", nil]]})
    assert csv == "Name,Count\r\n\"a, b\",1\r\n'=HYPERLINK(),\r\n"

    series =
      {:series, [%{key: "x", label: "X", points: [{~D[2026-01-01], 1}, {~D[2026-01-02], 2}]}]}

    assert Reports.to_csv(series) == "Date,X\r\n2026-01-01,1\r\n2026-01-02,2\r\n"
  end
end
