defmodule FireflyImport.Sources.NodeBB do
  @moduledoc """
  Imports a NodeBB forum from its database, MongoDB or Redis. NodeBB keeps
  the same data in both: hashes (`user:1`), sorted sets (`topics:tid`) and
  sets, which MongoDB holds as documents in its `objects` collection.
  Options:

    * `--mongo-url mongodb://user:password@host/nodebb`, or
    * `--redis-url redis://:password@host:6379/0`
    * `--uploads-dir`: NodeBB's `public/uploads` directory, for the images
      and files posts link (`/assets/uploads/files/...`) and avatars (else
      they keep linking to the old site)

  What it imports: users (passwords aren't, so they reset theirs; banned
  ones stay banned), groups (not the system ones) and members, categories
  (nested one level; disabled ones too), topics (pinned, locked; deleted
  ones left out) with their tags and posts (Markdown, as NodeBB keeps
  them; deleted posts as deleted), upvotes as likes, and permalinks for
  `/topic/...`, `/post/...`, `/category/...` and `/user/...` URLs.
  """

  @behaviour FireflyImport.Source

  alias FireflyImport.Markdown

  @page 500
  @upload_link ~r{(?:https?://[^/\s)]+)?(?:/assets)?/uploads/files/[^\s)"']+}

  @impl true
  def name, do: "nodebb"

  @impl true
  def switches, do: [mongo_url: :string, redis_url: :string, uploads_dir: :string]

  @impl true
  def usage do
    """
      --mongo-url URL    the NodeBB MongoDB database (mongodb://user:password@host/db), or
      --redis-url URL    its Redis database (redis://:password@host:6379/0)
      --uploads-dir DIR  its public/uploads directory
    """
  end

  @impl true
  def open(opts) do
    with {:ok, db} <- connect(opts),
         {:ok, _} <- check(db) do
      {:ok, %{db: db, uploads_dir: opts[:uploads_dir]}}
    end
  end

  defp connect(opts) do
    cond do
      url = opts[:mongo_url] ->
        with {:ok, conn} <- Mongo.start_link(url: url, pool_size: 1), do: {:ok, {:mongo, conn}}

      url = opts[:redis_url] ->
        case Redix.start_link(url, sync_connect: true, exit_on_disconnection: false) do
          {:ok, conn} -> {:ok, {:redis, conn}}
          {:error, error} -> {:error, Exception.message(error)}
        end

      true ->
        {:error, "--mongo-url or --redis-url is required"}
    end
  end

  # NodeBB's `global` object is always there.
  defp check(db) do
    case hash(db, "global") do
      %{} = global when map_size(global) > 0 -> {:ok, global}
      _ -> {:error, "no NodeBB data found (its global object is missing)"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def close(%{db: {_kind, conn}}) do
    GenServer.stop(conn)
    :ok
  end

  @impl true
  def stream(state, :users) do
    state
    |> each(&"user:#{&1}", "users:joindate")
    |> Stream.map(fn {uid, user} ->
      %{
        id: uid,
        username: decode(user["username"]),
        email: blank(user["email"]),
        confirmed: int(user["email:confirmed"]) == 1,
        created_at: time(user["joindate"]),
        last_seen_at: time(user["lastonline"]),
        bio: blank(user["aboutme"]),
        website: blank(user["website"]),
        location: blank(user["location"]),
        suspended_until: banned_until(user),
        suspend_reason: "Banned on the previous forum",
        avatar: file(state, user["uploadedpicture"])
      }
    end)
  end

  def stream(state, :groups) do
    state
    |> each(&"group:#{&1}", "groups:createtime")
    |> Stream.reject(fn {_name, group} -> int(group["system"]) == 1 end)
    |> Stream.map(fn {name, group} ->
      %{
        id: name,
        name: decode(name),
        description: blank(group["description"]),
        created_at: time(group["createtime"])
      }
    end)
  end

  def stream(state, :group_members) do
    state
    |> stream(:groups)
    |> Stream.flat_map(fn group ->
      state.db
      |> sorted("group:#{group.id}:members")
      |> Stream.map(&%{group_id: group.id, user_id: &1})
    end)
  end

  # Parents first.
  def stream(state, :categories) do
    categories = state |> each(&"category:#{&1}", "categories:cid") |> Enum.to_list()

    parents =
      Map.new(categories, fn {cid, category} -> {cid, to_string(category["parentCid"] || "0")} end)

    categories
    |> Enum.sort_by(fn {cid, category} -> {depth(parents, cid), int(category["order"]) || 0} end)
    |> Enum.map(fn {cid, category} ->
      parent = parents[cid]

      %{
        id: cid,
        title: decode(category["name"]),
        description: blank(category["description"]),
        color: category["bgColor"],
        position: int(category["order"]) || 0,
        parent_id: if(parent != "0", do: parent)
      }
    end)
  end

  def stream(%{uploads_dir: nil}, :uploads), do: []

  # The files posts link, each once.
  def stream(state, :uploads) do
    state
    |> posts()
    |> Stream.flat_map(fn {_tid, pid, post} ->
      for link <- links(post["content"]), do: {link, pid, post}
    end)
    |> Stream.uniq_by(fn {link, _pid, _post} -> upload_path(link) end)
    |> Stream.map(fn {link, _pid, post} ->
      path = upload_path(link)

      %{
        id: path,
        user_id: user_id(post["uid"]),
        filename: Path.basename(path),
        path: Path.join(state.uploads_dir, path)
      }
    end)
  end

  def stream(state, :topics) do
    state
    |> topics()
    |> Stream.map(fn {tid, topic} ->
      %{
        id: tid,
        category_id: to_string(topic["cid"]),
        title: decode(topic["title"]),
        tags: members(state.db, "topic:#{tid}:tags"),
        views: int(topic["viewcount"]) || 0,
        pinned_at: if(int(topic["pinned"]) == 1, do: time(topic["timestamp"])),
        closed_at:
          if(int(topic["locked"]) == 1,
            do: time(topic["lastposttime"]) || time(topic["timestamp"])
          ),
        created_at: time(topic["timestamp"])
      }
    end)
  end

  def stream(state, :posts) do
    state
    |> posts()
    |> Stream.map(fn {tid, pid, post} ->
      body = post["content"] || ""

      %{
        id: pid,
        topic_id: tid,
        user_id: user_id(post["uid"]),
        body: body,
        uploads:
          if(state.uploads_dir, do: Enum.map(links(body), &{&1, upload_path(&1)}), else: []),
        created_at: time(post["timestamp"]),
        edited_at: time(post["edited"]),
        deleted_at: if(int(post["deleted"]) == 1, do: time(post["timestamp"]))
      }
    end)
  end

  def stream(state, :likes) do
    state.db
    |> sorted("users:joindate")
    |> Stream.flat_map(fn uid ->
      state.db
      |> sorted("uid:#{uid}:upvote")
      |> Stream.map(&%{post_id: &1, user_id: uid})
    end)
  end

  def stream(state, :permalinks) do
    Stream.concat([
      state
      |> topics()
      |> Stream.flat_map(fn {tid, topic} ->
        [
          %{url: "topic/#{topic["slug"] || tid}", topic_id: tid},
          %{url: "topic/#{tid}", topic_id: tid}
        ]
      end),
      state.db |> sorted("posts:pid") |> Stream.map(&%{url: "post/#{&1}", post_id: &1}),
      state
      |> each(&"category:#{&1}", "categories:cid")
      |> Stream.flat_map(fn {cid, category} ->
        [
          %{url: "category/#{category["slug"] || cid}", category_id: cid},
          %{url: "category/#{cid}", category_id: cid}
        ]
      end),
      state
      |> each(&"user:#{&1}", "users:joindate")
      |> Stream.map(fn {uid, user} -> %{url: "user/#{user["userslug"]}", user_id: uid} end)
    ])
  end

  def stream(_state, _kind), do: []

  ## Records

  # The objects of the members of a sorted set: `{member, hash}`.
  defp each(state, key, set) do
    state.db
    |> sorted(set)
    |> Stream.map(&{&1, hash(state.db, key.(&1))})
    |> Stream.reject(fn {_id, object} -> object == %{} end)
  end

  defp topics(state) do
    state
    |> each(&"topic:#{&1}", "topics:tid")
    |> Stream.reject(fn {_tid, topic} -> int(topic["deleted"]) == 1 end)
  end

  # Each topic's posts, its main post first: `{tid, pid, post}`.
  defp posts(state) do
    state
    |> topics()
    |> Stream.flat_map(fn {tid, topic} ->
      main = if topic["mainPid"] in [nil, "", 0, "0"], do: [], else: [to_string(topic["mainPid"])]

      (main ++ Enum.to_list(sorted(state.db, "tid:#{tid}:posts")))
      |> Enum.uniq()
      |> Enum.map(&{tid, &1, hash(state.db, "post:#{&1}")})
      |> Enum.reject(fn {_tid, _pid, post} -> post == %{} end)
    end)
  end

  defp depth(parents, cid, seen \\ 0) do
    case parents[cid] do
      parent when parent in [nil, "0"] or seen > 10 -> seen
      parent -> depth(parents, parent, seen + 1)
    end
  end

  # NodeBB's uid 0 is a guest.
  defp user_id(uid) when uid in [nil, 0, "0"], do: nil
  defp user_id(uid), do: to_string(uid)

  defp banned_until(user) do
    cond do
      int(user["banned"]) != 1 -> nil
      (int(user["banned:expire"]) || 0) > 0 -> time(user["banned:expire"])
      true -> ~U[2999-01-01 00:00:00Z]
    end
  end

  defp links(nil), do: []
  defp links(body), do: @upload_link |> Regex.scan(body) |> List.flatten() |> Enum.uniq()

  # A link's path in the uploads directory: files/<name>.
  defp upload_path(link) do
    [_, rest] = String.split(link, "/uploads/", parts: 2)
    URI.decode(rest)
  end

  defp file(%{uploads_dir: nil}, _url), do: nil
  defp file(_state, url) when url in [nil, ""], do: nil

  defp file(state, url) do
    case String.split(url, "/uploads/", parts: 2) do
      [_, rest] ->
        %{filename: Path.basename(rest), path: Path.join(state.uploads_dir, URI.decode(rest))}

      [_] ->
        nil
    end
  end

  ## Reading the database

  defp hash({:redis, conn}, key) do
    conn
    |> Redix.command!(["HGETALL", key])
    |> Enum.chunk_every(2)
    |> Map.new(fn [field, value] -> {field, value} end)
  end

  defp hash({:mongo, conn}, key) do
    case Mongo.find_one(conn, "objects", %{"_key" => key}) do
      %{} = doc -> Map.drop(doc, ["_id", "_key"])
      nil -> %{}
      {:error, error} -> raise error
    end
  end

  # A sorted set's members by score, page by page.
  defp sorted({:redis, conn}, key) do
    pages =
      Stream.unfold(0, fn
        nil ->
          nil

        start ->
          case Redix.command!(conn, ["ZRANGE", key, start, start + @page - 1]) do
            [] -> nil
            page -> {page, if(length(page) < @page, do: nil, else: start + @page)}
          end
      end)

    Stream.concat(pages)
  end

  defp sorted({:mongo, conn}, key) do
    conn
    |> Mongo.find("objects", %{"_key" => key}, sort: [score: 1], projection: %{"value" => 1})
    |> Stream.map(&to_string(&1["value"]))
  end

  defp members({:redis, conn}, key), do: conn |> Redix.command!(["SMEMBERS", key]) |> Enum.sort()

  defp members({:mongo, conn}, key) do
    case Mongo.find_one(conn, "objects", %{"_key" => key}) do
      %{"members" => members} -> Enum.sort(members)
      _ -> []
    end
  end

  ## Values (strings in Redis, typed in MongoDB)

  defp int(nil), do: nil
  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp int(_value), do: nil

  defp time(value) do
    case int(value) do
      ms when is_integer(ms) and ms > 0 -> DateTime.from_unix!(ms, :millisecond)
      _ -> nil
    end
  end

  defp decode(nil), do: nil
  defp decode(text), do: text |> to_string() |> Markdown.decode_entities()

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: to_string(value)
end
