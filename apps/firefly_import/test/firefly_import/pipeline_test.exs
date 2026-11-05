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

  # Postgres can't store a NUL character; an upload's bytes may hold one.
  test "NUL characters are stripped from the text, not from files" do
    records = %{
      users: [%{id: 5, username: <<"an", 0, "n">>, email: "ann@example.com"}],
      topics: [%{id: 1, title: <<"Ke", 0, "pt">>, user_id: 5}],
      posts: [%{id: 10, topic_id: 1, user_id: 5, body: <<"Fir", 0, "st">>}],
      uploads: [%{id: 3, user_id: 5, filename: <<"a", 0, ".pdf">>, data: <<"%PDF-1.4", 0, 1>>}]
    }

    assert {:ok, run} = Pipeline.run(Fake, records: records, skip_after: true)
    assert run.counts["posts"] == %{"imported" => 1}
    assert run.counts["uploads"] == %{"imported" => 1}

    thread = Repo.get_by!(Thread, title: "Kept") |> Repo.preload(posts: :user)
    assert [%{body: "First", user: %{username: "ann"}}] = thread.posts

    upload = Repo.get!(Firefly.Uploads.Upload, Import.local_id("fake", "upload", 3))
    assert upload.filename == "a.pdf"
    assert Firefly.Uploads.contents(upload) == {:ok, <<"%PDF-1.4", 0, 1>>}
  end
end
