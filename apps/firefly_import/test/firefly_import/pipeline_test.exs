defmodule FireflyImport.PipelineTest do
  use Firefly.DataCase, async: false

  alias Firefly.{Import, Repo}
  alias Firefly.Discussion.{Post, Thread}
  alias FireflyImport.Pipeline

  # A source made of records given in the options.
  defmodule Fake do
    @behaviour FireflyImport.Source

    @impl true
    def name, do: "fake"
    @impl true
    def switches, do: []
    @impl true
    def usage, do: ""
    @impl true
    def open(opts), do: {:ok, opts[:records]}
    @impl true
    def stream(records, kind), do: Map.get(records, kind, [])
    @impl true
    def close(_records), do: :ok
  end

  test "a record that fails is counted and logged, and the rest of its batch imported" do
    records = %{
      topics: [%{id: 1, title: "Kept"}],
      posts: [
        %{id: 10, topic_id: 1, user_id: 5, body: "First", user_names: %{5 => "ann"}},
        %{id: 11, topic_id: 404, user_id: 5, body: "Orphan"},
        %{id: 12, topic_id: 1, user_id: nil, body: "Second"}
      ]
    }

    assert {:ok, run} = Pipeline.run(Fake, records: records, skip_after: true)
    assert run.counts["posts"] == %{"imported" => 2, "failed" => 1}
    assert Enum.any?(run.log, &(&1 =~ "posts 11: thread 404 wasn't imported"))

    thread = Repo.get_by!(Thread, title: "Kept") |> Repo.preload(posts: :user)

    assert Enum.map(thread.posts, &{&1.body, &1.user.username}) == [
             {"First", "ann"},
             {"Second", "ghost"}
           ]

    assert Repo.get!(Firefly.Discussion.Category, thread.category_id).title == "Imported"
    assert Repo.aggregate(Post, :count) == 2
    assert Import.local_id("fake", "post", 11) == nil
  end
end
