defmodule FireflyImport.NodeBBFixture do
  @moduledoc """
  A small NodeBB database, loaded into Redis or MongoDB the way NodeBB
  keeps it: hashes, sorted sets and sets.
  """

  # Test support: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @t 1_600_000_000_000

  @doc "The objects: `{:hash, key, fields}`, `{:zset, key, [{score, member}]}`, `{:set, key, members}`."
  def objects do
    [
      {:hash, "global", %{"nextUid" => 4, "nextTid" => 3, "nextPid" => 5}},
      {:zset, "users:joindate", [{@t, "1"}, {@t + 1, "2"}, {@t + 2, "3"}]},
      {:hash, "user:1",
       %{
         "uid" => 1,
         "username" => "admin",
         "userslug" => "admin",
         "email" => "admin@example.com",
         "email:confirmed" => 1,
         "joindate" => @t,
         "lastonline" => @t + 1000,
         "aboutme" => "I run this.",
         "uploadedpicture" => "/assets/uploads/files/1600000000-logo.png"
       }},
      {:hash, "user:2",
       %{"uid" => 2, "username" => "Jane Doe", "userslug" => "jane-doe", "joindate" => @t + 1}},
      {:hash, "user:3",
       %{
         "uid" => 3,
         "username" => "troll",
         "userslug" => "troll",
         "joindate" => @t + 2,
         "banned" => 1
       }},
      {:zset, "groups:createtime", [{@t, "administrators"}, {@t + 1, "Helpers"}]},
      {:hash, "group:administrators", %{"name" => "administrators", "system" => 1}},
      {:hash, "group:Helpers",
       %{"name" => "Helpers", "description" => "They help", "createtime" => @t}},
      {:zset, "group:Helpers:members", [{@t, "2"}]},
      {:zset, "categories:cid", [{1, "1"}, {2, "2"}]},
      {:hash, "category:1",
       %{
         "cid" => 1,
         "name" => "General &amp; more",
         "slug" => "1/general-more",
         "parentCid" => 0,
         "order" => 1,
         "bgColor" => "#336699"
       }},
      {:hash, "category:2",
       %{"cid" => 2, "name" => "Help", "slug" => "2/help", "parentCid" => 1, "order" => 1}},
      {:zset, "topics:tid", [{@t, "1"}, {@t + 1, "2"}]},
      {:hash, "topic:1",
       %{
         "tid" => 1,
         "cid" => 2,
         "uid" => 1,
         "title" => "Welcome &amp; hello",
         "slug" => "1/welcome-hello",
         "timestamp" => @t,
         "viewcount" => 9,
         "pinned" => 1,
         "locked" => 1,
         "mainPid" => 1
       }},
      {:set, "topic:1:tags", ["intro", "news"]},
      {:zset, "tid:1:posts", [{@t + 10, "2"}, {@t + 20, "3"}]},
      {:hash, "topic:2",
       %{
         "tid" => 2,
         "cid" => 1,
         "uid" => 3,
         "title" => "Deleted",
         "timestamp" => @t,
         "deleted" => 1,
         "mainPid" => 4
       }},
      {:zset, "posts:pid", [{@t, "1"}, {@t + 10, "2"}, {@t + 20, "3"}, {@t + 30, "4"}]},
      {:hash, "post:1",
       %{
         "pid" => 1,
         "tid" => 1,
         "uid" => 1,
         "content" => "**Hi** all ![logo](/assets/uploads/files/1600000000-logo.png)",
         "timestamp" => @t,
         "edited" => @t + 5000
       }},
      {:hash, "post:2",
       %{"pid" => 2, "tid" => 1, "uid" => 2, "content" => "Hello!", "timestamp" => @t + 10}},
      {:hash, "post:3",
       %{
         "pid" => 3,
         "tid" => 1,
         "uid" => 0,
         "content" => "A guest, deleted",
         "timestamp" => @t + 20,
         "deleted" => 1
       }},
      {:hash, "post:4",
       %{"pid" => 4, "tid" => 2, "uid" => 3, "content" => "Gone", "timestamp" => @t + 30}},
      {:zset, "uid:2:upvote", [{@t + 40, "1"}]},
      {:zset, "uid:3:upvote", [{@t + 40, "1"}, {@t + 40, "2"}]}
    ]
  end

  @doc "Loads the objects into the Redis database at `url` (emptied first)."
  def load_redis(url) do
    {:ok, conn} = Redix.start_link(url)
    Redix.command!(conn, ["FLUSHDB"])

    for object <- objects() do
      case object do
        {:hash, key, fields} ->
          Redix.command!(conn, [
            "HSET",
            key | Enum.flat_map(fields, fn {k, v} -> [k, to_string(v)] end)
          ])

        {:zset, key, pairs} ->
          Redix.command!(conn, [
            "ZADD",
            key | Enum.flat_map(pairs, fn {s, m} -> [to_string(s), m] end)
          ])

        {:set, key, members} ->
          Redix.command!(conn, ["SADD", key | members])
      end
    end

    GenServer.stop(conn)
  end

  @doc "Loads the objects into the MongoDB database at `url` (emptied first)."
  def load_mongo(url) do
    {:ok, conn} = Mongo.start_link(url: url)
    Mongo.delete_many!(conn, "objects", %{})

    docs =
      Enum.flat_map(objects(), fn
        {:hash, key, fields} ->
          [Map.put(fields, "_key", key)]

        {:zset, key, pairs} ->
          for {score, member} <- pairs, do: %{"_key" => key, "value" => member, "score" => score}

        {:set, key, members} ->
          [%{"_key" => key, "members" => members}]
      end)

    Mongo.insert_many!(conn, "objects", docs)
    GenServer.stop(conn)
  end
end
