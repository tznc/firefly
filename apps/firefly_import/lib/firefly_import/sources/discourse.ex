defmodule FireflyImport.Sources.Discourse do
  @moduledoc """
  Imports a Discourse forum from its PostgreSQL database: a running
  Discourse's, or a backup's dump restored into a database of its own
  (`gunzip dump.sql.gz` from the backup, then `createdb discourse && psql
  discourse < dump.sql`). Options:

    * `--source-url postgres://user:password@host/discourse` (required)
    * `--uploads-dir`: the uploads directory (the backup's `uploads/default`,
      or a running site's `public/uploads/default`), holding `original/...`.
      Without it, uploads and avatars aren't imported

  What it imports: users (with their email, profile, trust level,
  suspension and silencing, DiscourseConnect and social login accounts, so
  they log in the same way, and avatars), groups and their members
  (automatic ones aside), categories (nested; restricted to groups), tags
  and tag groups, topics (pinned, closed, archived, views, tags) and their
  posts from the raw Markdown (quotes, upload links and image sizes
  converted; small actions and whispers left out), likes, bookmarks, polls
  (single, multiple and ranked choice), accepted answers (the Solved
  plugin), private messages, uploads, and permalinks for the old topic,
  category, user and tag URLs plus Discourse's own permalinks.
  """

  @behaviour FireflyImport.Source

  alias FireflyImport.{Markdown, SQL}

  # Social logins as Firefly's providers call them.
  @providers %{
    "github" => "github",
    "google_oauth2" => "google",
    "discord" => "discord",
    "facebook" => "facebook",
    "twitter" => "x",
    "apple" => "apple",
    "oidc" => "oidc"
  }

  # Upload links in posts: `upload://<base62 sha1>.ext`, and full URLs
  # ending in `/<sha1>.ext`.
  @short_url ~r{upload://([0-9A-Za-z]+)(?:\.[A-Za-z0-9]+)?}
  @full_url ~r<(?:https?:)?(?://[^\s)"']+)?/uploads/[^\s)"']*?/([0-9a-f]{40})\.[A-Za-z0-9]+>

  # Regular posts and moderator actions (not small actions or whispers).
  @post_types [1, 2]

  @impl true
  def name, do: "discourse"

  @impl true
  def switches, do: [source_url: :string, uploads_dir: :string]

  @impl true
  def usage do
    """
      --source-url URL    the Discourse database (postgres://user:password@host/db)
      --uploads-dir DIR   its uploads directory (uploads/default, with original/ in it)
    """
  end

  @impl true
  def open(opts) do
    with url when is_binary(url) <- opts[:source_url] || {:error, "--source-url is required"},
         {:ok, conn} <-
           Postgrex.start_link(SQL.url_options(url) ++ [pool_size: 1, timeout: :infinity]),
         {:ok, _} <- Postgrex.query(conn, "SELECT 1 FROM posts LIMIT 1", []) do
      {:ok, %{conn: conn, uploads_dir: opts[:uploads_dir], tables: tables(conn)}}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, %{postgres: %{message: message}}} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @impl true
  def close(%{conn: conn}) do
    GenServer.stop(conn)
    :ok
  end

  defp tables(conn) do
    conn
    |> query(
      "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = current_schema()",
      []
    )
    |> Enum.group_by(& &1.table_name, & &1.column_name)
  end

  defp column?(state, table, column), do: column in Map.get(state.tables, table, [])
  defp table?(state, table), do: Map.has_key?(state.tables, table)

  @impl true
  def stream(state, :users) do
    """
    SELECT u.id, u.username, u.name, u.created_at, u.updated_at, u.last_seen_at, u.active,
      u.trust_level, u.suspended_till, u.silenced_till, e.email, p.bio_raw, p.website,
      p.location, a.url AS avatar_url, a.original_filename AS avatar_filename
    FROM users u
    LEFT JOIN user_emails e ON e.user_id = u.id AND e."primary"
    LEFT JOIN user_profiles p ON p.user_id = u.id
    LEFT JOIN uploads a ON a.id = u.uploaded_avatar_id
    WHERE u.id > $1
    ORDER BY u.id LIMIT $2
    """
    |> paged(state, "u.id")
    |> Stream.map(&user(state, &1))
  end

  def stream(%{conn: conn}, :groups) do
    conn
    |> query(
      "SELECT id, name, full_name, bio_raw, created_at FROM groups WHERE NOT automatic ORDER BY id",
      []
    )
    |> Enum.map(&%{id: &1.id, name: &1.name, description: &1.bio_raw, created_at: &1.created_at})
  end

  def stream(state, :group_members) do
    """
    SELECT gu.id, gu.group_id, gu.user_id, gu.owner FROM group_users gu
    JOIN groups g ON g.id = gu.group_id AND NOT g.automatic
    WHERE gu.id > $1 ORDER BY gu.id LIMIT $2
    """
    |> paged(state, "gu.id")
    |> Stream.map(&%{group_id: &1.group_id, user_id: &1.user_id, owner: &1.owner})
  end

  def stream(%{conn: conn} = state, :categories) do
    accepted = accepted_answer_categories(state)

    conn
    |> query(
      """
      WITH RECURSIVE tree AS (
        SELECT id, 0 AS depth FROM categories WHERE parent_category_id IS NULL
        UNION ALL
        SELECT c.id, tree.depth + 1 FROM categories c JOIN tree ON c.parent_category_id = tree.id
      )
      SELECT c.id, c.name, c.description, c.color, c.position, c.parent_category_id,
        c.read_restricted, c.created_at,
        ARRAY(SELECT cg.group_id FROM category_groups cg WHERE cg.category_id = c.id) AS group_ids
      FROM categories c JOIN tree ON tree.id = c.id
      ORDER BY tree.depth, c.position, c.id
      """,
      []
    )
    |> Enum.map(fn category ->
      %{
        id: category.id,
        title: category.name,
        description: category.description && Markdown.from_html(category.description),
        color: category.color,
        position: category.position,
        parent_id: category.parent_category_id,
        group_ids: if(category.read_restricted, do: category.group_ids, else: []),
        allow_accepted_answers: category.id in accepted,
        created_at: category.created_at
      }
    end)
  end

  def stream(%{conn: conn} = state, :tags) do
    if table?(state, "tags") do
      conn
      |> query(
        """
        SELECT DISTINCT ON (t.id) t.id, t.name, g.name AS group_name FROM tags t
        LEFT JOIN tag_group_memberships m ON m.tag_id = t.id
        LEFT JOIN tag_groups g ON g.id = m.tag_group_id
        ORDER BY t.id, g.id
        """,
        []
      )
      |> Enum.map(&%{id: &1.id, name: &1.name, group: &1.group_name})
    else
      []
    end
  end

  def stream(%{uploads_dir: nil}, :uploads), do: []

  def stream(state, :uploads) do
    """
    SELECT id, user_id, original_filename, url FROM uploads
    WHERE id > $1 AND id NOT IN (SELECT uploaded_avatar_id FROM users WHERE uploaded_avatar_id IS NOT NULL)
    ORDER BY id LIMIT $2
    """
    |> paged(state, "id")
    |> Stream.map(
      &%{
        id: &1.id,
        user_id: &1.user_id,
        filename: &1.original_filename,
        path: upload_path(state, &1.url)
      }
    )
  end

  def stream(state, :topics) do
    """
    SELECT t.id, t.title, t.category_id, t.views, t.pinned_at, t.closed, t.archived,
      t.created_at, t.updated_at, t.bumped_at,
      #{topic_tags(state)} AS tags
    FROM topics t
    WHERE t.id > $1 AND t.archetype = 'regular' AND t.deleted_at IS NULL
    ORDER BY t.id LIMIT $2
    """
    |> paged(state, "t.id")
    |> Stream.map(fn topic ->
      %{
        id: topic.id,
        title: topic.title,
        category_id: topic.category_id,
        views: topic.views,
        tags: topic.tags,
        pinned_at: topic.pinned_at,
        closed_at: if(topic.closed, do: topic.bumped_at || topic.updated_at),
        archived_at: if(topic.archived, do: topic.updated_at),
        created_at: topic.created_at,
        updated_at: topic.updated_at
      }
    end)
  end

  def stream(state, :posts) do
    state
    |> topic_posts("regular")
    |> Stream.map(fn post ->
      {body, uploads} = body(state, post.raw, post.cooked)

      %{
        id: post.id,
        topic_id: post.topic_id,
        user_id: post.user_id,
        body: body,
        uploads: uploads,
        wiki: post.wiki,
        created_at: post.created_at,
        updated_at: post.updated_at,
        edited_at: if(post.version > 1, do: post.last_version_at),
        deleted_at: post.deleted_at
      }
    end)
  end

  def stream(state, :likes) do
    """
    SELECT pa.id, pa.post_id, pa.user_id, pa.created_at FROM post_actions pa
    JOIN posts p ON p.id = pa.post_id
    JOIN topics t ON t.id = p.topic_id AND t.archetype = 'regular' AND t.deleted_at IS NULL
    WHERE pa.id > $1 AND pa.post_action_type_id = 2 AND pa.deleted_at IS NULL
    ORDER BY pa.id LIMIT $2
    """
    |> paged(state, "pa.id")
    |> Stream.map(&Map.delete(&1, :id))
  end

  def stream(state, :bookmarks) do
    post_id =
      if column?(state, "bookmarks", "bookmarkable_id"),
        do: "b.bookmarkable_id AND b.bookmarkable_type = 'Post'",
        else: "b.post_id"

    if table?(state, "bookmarks") do
      """
      SELECT b.id, p.id AS post_id, b.user_id, b.name, b.created_at FROM bookmarks b
      JOIN posts p ON p.id = #{post_id}
      JOIN topics t ON t.id = p.topic_id AND t.archetype = 'regular' AND t.deleted_at IS NULL
      WHERE b.id > $1 ORDER BY b.id LIMIT $2
      """
      |> paged(state, "b.id")
      |> Stream.map(
        &%{post_id: &1.post_id, user_id: &1.user_id, note: &1.name, created_at: &1.created_at}
      )
    else
      []
    end
  end

  def stream(%{conn: conn} = state, :polls) do
    if table?(state, "polls") do
      rank = if column?(state, "poll_votes", "rank"), do: "v.rank", else: "NULL::integer"

      """
      SELECT p.id, p.post_id, p.type, p.status, p.results, p.visibility, p.min, p.max,
        p.close_at, p.created_at, p.updated_at
      FROM polls p
      WHERE p.id > $1 AND p.type <> 2
        AND p.id = (SELECT min(id) FROM polls WHERE post_id = p.post_id)
      ORDER BY p.id LIMIT $2
      """
      |> paged(state, "p.id")
      |> Stream.map(&poll(conn, &1, rank))
    else
      []
    end
  end

  def stream(%{conn: conn} = state, :solved) do
    cond do
      table?(state, "discourse_solved_solved_topics") ->
        query(
          conn,
          "SELECT topic_id, answer_post_id AS post_id FROM discourse_solved_solved_topics",
          []
        )

      table?(state, "topic_custom_fields") ->
        query(
          conn,
          """
          SELECT topic_id, value::integer AS post_id FROM topic_custom_fields
          WHERE name = 'accepted_answer_post_id' AND value ~ '^[0-9]+$'
          """,
          []
        )

      true ->
        []
    end
  end

  def stream(state, :conversations) do
    """
    SELECT t.id, t.title, t.user_id, t.created_at,
      ARRAY(SELECT user_id FROM topic_allowed_users WHERE topic_id = t.id) AS participant_ids,
      (SELECT min(group_id) FROM topic_allowed_groups WHERE topic_id = t.id) AS group_id
    FROM topics t
    WHERE t.id > $1 AND t.archetype = 'private_message' AND t.deleted_at IS NULL
    ORDER BY t.id LIMIT $2
    """
    |> paged(state, "t.id")
  end

  def stream(state, :messages) do
    state
    |> topic_posts("private_message")
    |> Stream.reject(& &1.deleted_at)
    |> Stream.map(fn post ->
      {body, uploads} = body(state, post.raw, post.cooked)

      %{
        id: post.id,
        conversation_id: post.topic_id,
        user_id: post.user_id,
        body: body,
        uploads: uploads,
        created_at: post.created_at
      }
    end)
  end

  def stream(state, :permalinks) do
    Stream.concat([
      topic_permalinks(state),
      category_permalinks(state),
      "SELECT id, username FROM users WHERE id > $1 ORDER BY id LIMIT $2"
      |> paged(state, "id")
      |> Stream.map(&%{url: "u/#{&1.username}", user_id: &1.id}),
      tag_permalinks(state),
      discourse_permalinks(state)
    ])
  end

  def stream(_state, _kind), do: []

  ## Users

  defp user(state, user) do
    %{
      id: user.id,
      username: user.username,
      name: user.name,
      email: user.email,
      confirmed: user.active,
      created_at: user.created_at,
      updated_at: user.updated_at,
      last_seen_at: user.last_seen_at,
      trust_level: user.trust_level,
      bio: user.bio_raw,
      website: user.website,
      location: user.location,
      suspended_until: future(user.suspended_till),
      suspend_reason: "Suspended on the previous forum",
      silenced_until: future(user.silenced_till),
      identities: identities(state, user.id),
      avatar: avatar(state, user)
    }
  end

  # Only a suspension or silencing still in force carries over.
  defp future(nil), do: nil
  defp future(at), do: if(NaiveDateTime.after?(at, NaiveDateTime.utc_now()), do: at)

  defp identities(%{conn: conn} = state, user_id) do
    sso =
      if table?(state, "single_sign_on_records"),
        do:
          for(
            %{external_id: uid} <-
              query(conn, "SELECT external_id FROM single_sign_on_records WHERE user_id = $1", [
                user_id
              ]),
            do: %{provider: "discourse_connect", uid: uid}
          ),
        else: []

    social =
      if table?(state, "user_associated_accounts"),
        do:
          for(
            %{provider_name: name, provider_uid: uid} <-
              query(
                conn,
                "SELECT provider_name, provider_uid FROM user_associated_accounts WHERE user_id = $1",
                [user_id]
              ),
            provider = @providers[name],
            do: %{provider: provider, uid: uid}
          ),
        else: []

    sso ++ social
  end

  defp avatar(%{uploads_dir: nil}, _user), do: nil
  defp avatar(_state, %{avatar_url: nil}), do: nil

  defp avatar(state, user),
    do: %{
      filename: user.avatar_filename || "avatar.png",
      path: upload_path(state, user.avatar_url)
    }

  ## Categories and topics

  defp accepted_answer_categories(%{conn: conn} = state) do
    if table?(state, "category_custom_fields") do
      conn
      |> query(
        "SELECT category_id FROM category_custom_fields WHERE name = 'enable_accepted_answers' AND value = 'true'",
        []
      )
      |> Enum.map(& &1.category_id)
    else
      []
    end
  end

  defp topic_tags(state) do
    if table?(state, "topic_tags"),
      do:
        "ARRAY(SELECT tg.name FROM topic_tags tt JOIN tags tg ON tg.id = tt.tag_id WHERE tt.topic_id = t.id)",
      else: "ARRAY[]::text[]"
  end

  # Posts of the topics of an archetype, each topic's in order.
  defp topic_posts(%{conn: conn}, archetype) do
    SQL.paged(fn last, page ->
      {topic_id, post_number} = if last, do: {last.topic_id, last.post_number}, else: {0, 0}

      query(
        conn,
        """
        SELECT p.id, p.topic_id, p.post_number, p.user_id, p.raw, p.cooked, p.wiki, p.version,
          p.last_version_at, p.created_at, p.updated_at, p.deleted_at
        FROM posts p
        JOIN topics t ON t.id = p.topic_id AND t.archetype = $3 AND t.deleted_at IS NULL
        WHERE (p.topic_id, p.post_number) > ($1, $2) AND p.post_type = ANY($4)
        ORDER BY p.topic_id, p.post_number LIMIT $5
        """,
        [topic_id, post_number, archetype, @post_types, page]
      )
    end)
  end

  ## Post bodies

  # The raw Markdown (the cooked HTML converted when there's none) made
  # Firefly's, and the uploads it shows.
  defp body(state, raw, cooked) do
    markdown =
      if raw in [nil, ""],
        do: Markdown.from_html(cooked),
        else: raw |> convert_raw() |> Markdown.from_bbcode()

    {markdown, upload_refs(state, markdown)}
  end

  @doc false
  def convert_raw(raw) do
    raw
    # Polls are imported as polls.
    |> String.replace(~r/\[poll[^\]]*\].*?\[\/poll\]/s, "")
    # [quote="name, post:3, topic:12"] => [quote=name]
    |> String.replace(~r/\[quote="([^",\]]+)(?:,[^"\]]*)?"\]/, fn quote ->
      [_, name] = Regex.run(~r/\[quote="([^",\]]+)/, quote)
      "[quote=#{username(name)}]"
    end)
    # @first.last => @first_last, as the username is imported
    |> String.replace(~r/(?<![\w.@])@(\w[\w.-]*\w)/u, fn "@" <> name -> "@" <> username(name) end)
    # ![alt|690x388](...) => ![alt](...)
    |> String.replace(~r/!\[([^\]|]*)\|[^\]]*\]\(/, "![\\1](")
    |> String.trim()
  end

  # A Discourse username as Firefly's (see `Firefly.Import.Writer.unique_username/1`).
  defp username(name), do: name |> String.replace(~r/[^A-Za-z0-9_-]+/, "_") |> String.trim("_")

  # `upload://<base62 sha1>.ext` short URLs and `/uploads/.../<sha1>.ext`
  # full ones, with the source upload each is.
  defp upload_refs(%{uploads_dir: nil}, _body), do: []

  defp upload_refs(%{conn: conn}, body) do
    short = for [ref, name] <- Regex.scan(@short_url, body), do: {ref, short_sha1s(name)}
    full = for [ref, sha1] <- Regex.scan(@full_url, body), do: {ref, [sha1]}
    refs = Enum.uniq(short ++ full)

    case refs do
      [] ->
        []

      refs ->
        ids =
          conn
          |> query("SELECT id, sha1 FROM uploads WHERE sha1 = ANY($1)", [
            Enum.flat_map(refs, &elem(&1, 1))
          ])
          |> Map.new(&{&1.sha1, &1.id})

        for {ref, sha1s} <- refs, id = Enum.find_value(sha1s, &ids[&1]), do: {ref, id}
    end
  end

  # The sha1 an `upload://` name encodes: base 62, in either digit order
  # Discourse versions used.
  defp short_sha1s(short) do
    for alphabet <- [
          ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
          ~c"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        ] do
      short
      |> String.to_charlist()
      |> Enum.reduce(0, fn char, acc -> acc * 62 + Enum.find_index(alphabet, &(&1 == char)) end)
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(40, "0")
    end
  end

  # Where an upload's file is in the uploads directory.
  defp upload_path(%{uploads_dir: dir}, url) do
    case String.split(url || "", "/original/", parts: 2) do
      [_, rest] -> Path.join([dir, "original", rest])
      [_] -> Path.join(dir, Path.basename(url || ""))
    end
  end

  ## Polls

  defp poll(conn, poll, rank) do
    options =
      conn
      |> query("SELECT id, html FROM poll_options WHERE poll_id = $1 ORDER BY id", [poll.id])
      |> Enum.map(&{&1.id, &1.html |> Floki.parse_fragment!() |> Floki.text() |> String.trim()})

    votes =
      conn
      |> query(
        "SELECT v.user_id, v.poll_option_id, #{rank} AS rank FROM poll_votes v WHERE v.poll_id = $1",
        [poll.id]
      )
      |> Enum.map(&{&1.user_id, &1.poll_option_id, &1.rank})

    %{
      id: poll.id,
      post_id: poll.post_id,
      kind: Enum.at(~w(single multiple single ranked), poll.type, "single"),
      min_choices: if(poll.type == 1, do: poll.min),
      max_choices: if(poll.type == 1, do: poll.max),
      results: Enum.at(~w(always voted closed closed), poll.results, "always"),
      public: poll.visibility == 1,
      close_at: poll.close_at,
      closed_at: if(poll.status == 1, do: poll.close_at || poll.updated_at),
      options: options,
      votes: votes,
      created_at: poll.created_at
    }
  end

  ## Permalinks

  defp topic_permalinks(state) do
    """
    SELECT id, slug FROM topics
    WHERE id > $1 AND archetype = 'regular' AND deleted_at IS NULL
    ORDER BY id LIMIT $2
    """
    |> paged(state, "id")
    |> Stream.flat_map(
      &[%{url: "t/#{&1.slug}/#{&1.id}", topic_id: &1.id}, %{url: "t/#{&1.id}", topic_id: &1.id}]
    )
  end

  defp category_permalinks(%{conn: conn}) do
    categories =
      conn
      |> query("SELECT id, slug, parent_category_id FROM categories", [])
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(Map.values(categories), fn category ->
      path =
        case categories[category.parent_category_id] do
          nil -> category.slug
          parent -> "#{parent.slug}/#{category.slug}"
        end

      [
        %{url: "c/#{path}", category_id: category.id},
        %{url: "c/#{path}/#{category.id}", category_id: category.id}
      ]
    end)
  end

  defp tag_permalinks(%{conn: conn} = state) do
    if table?(state, "tags"),
      do:
        Enum.map(
          query(conn, "SELECT name FROM tags", []),
          &%{url: "tag/#{&1.name}", tag: &1.name}
        ),
      else: []
  end

  defp discourse_permalinks(%{conn: conn} = state) do
    if table?(state, "permalinks") do
      conn
      |> query(
        """
        SELECT p.url, p.topic_id, p.post_id, p.category_id, p.external_url, tg.name AS tag
        FROM permalinks p LEFT JOIN tags tg ON tg.id = p.tag_id
        """,
        []
      )
      |> Enum.map(&Map.reject(&1, fn {_key, value} -> is_nil(value) end))
    else
      []
    end
  end

  ## Queries

  # The query's rows page by page, keyed by `key` (an id column, `$1` the
  # last one, `$2` the page size).
  defp paged(sql, %{conn: conn}, key) do
    field = key |> String.split(".") |> List.last() |> String.to_atom()

    SQL.paged(fn last, page ->
      query(conn, sql, [if(last, do: Map.fetch!(last, field), else: 0), page])
    end)
  end

  defp query(conn, sql, params), do: conn |> Postgrex.query!(sql, params) |> SQL.maps()
end
