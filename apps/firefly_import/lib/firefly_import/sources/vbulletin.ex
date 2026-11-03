defmodule FireflyImport.Sources.VBulletin do
  @moduledoc """
  Imports a vBulletin 4 or 5 forum from its MySQL (or MariaDB) database
  (which version it is, it tells from the tables: vBulletin 5 keeps
  everything as nodes). Options:

    * `--source-url mysql://user:password@host/vbulletin` (required)
    * `--table-prefix` (default none)
    * `--attachments-dir`: where attachments are, when vBulletin keeps them
      in the file system (`<dir>/<user id's digits>/<file id>.attach`);
      otherwise they're read from the database

  What it imports: users (passwords aren't, so they reset theirs), custom
  user groups and their members (primary and additional), forums as
  categories (nested one level), threads (sticky ones pinned, closed ones
  closed, moderated ones left out) and their posts (vBulletin 5's comments
  too) with their BBCode as Markdown, deleted posts as deleted,
  attachments (inline where the post placed them, else at the end),
  private messages, and permalinks for `showthread.php?t=`,
  `showthread.php?p=`, `showpost.php?p=`, `forumdisplay.php?f=` and
  `member.php?u=` URLs.
  """

  @behaviour FireflyImport.Source

  alias FireflyImport.{Markdown, MySQL}

  # vBulletin's own user groups (guests, registered, admins...) are 1 to 8.
  @default_groups 8
  # vBulletin 5's root channel of the forums.
  @forum_root_guid "vbulletin-4ecbdf567f2c35.70389590"
  @images ~w(.png .jpg .jpeg .gif .webp)

  @impl true
  def name, do: "vbulletin"

  @impl true
  def switches, do: [source_url: :string, table_prefix: :string, attachments_dir: :string]

  @impl true
  def usage do
    """
      --source-url URL       the vBulletin database (mysql://user:password@host/db)
      --table-prefix PREFIX  its tables' prefix (default none)
      --attachments-dir DIR  where its attachments are, if in the file system
    """
  end

  @impl true
  def open(opts) do
    prefix = opts[:table_prefix] || ""

    with {:ok, conn} <- MySQL.connect(opts[:source_url], prefix <> "user") do
      state = %{conn: conn, prefix: prefix, attachments_dir: opts[:attachments_dir]}

      if MySQL.table?(conn, prefix <> "node"),
        do: {:ok, Map.merge(state, vb5(state))},
        else: {:ok, Map.put(state, :version, 4)}
    end
  end

  # vBulletin 5: its content types, and the forum channels (all under the
  # forum root, parents first).
  defp vb5(state) do
    types =
      Map.new(
        query(state, "SELECT contenttypeid, class FROM #{t(state, "contenttype")}"),
        &{&1.class, &1.contenttypeid}
      )

    channels =
      query(
        state,
        """
        SELECT n.nodeid, n.parentid, n.title, n.description, n.displayorder, n.publishdate, c.depth
        FROM #{t(state, "node")} n
        JOIN #{t(state, "closure")} c ON c.child = n.nodeid
        JOIN #{t(state, "channel")} root ON root.nodeid = c.parent AND root.guid = ?
        WHERE n.contenttypeid = ? AND c.depth > 0
        ORDER BY c.depth, n.displayorder, n.nodeid
        """,
        [@forum_root_guid, types["Channel"]]
      )

    %{version: 5, types: types, channels: channels, channel_ids: Enum.map(channels, & &1.nodeid)}
  end

  @impl true
  def close(%{conn: conn}), do: MySQL.close(conn)

  @impl true
  def stream(state, :users) do
    "SELECT * FROM #{t(state, "user")} WHERE userid > ? ORDER BY userid LIMIT ?"
    |> paged(state, :userid)
    |> Stream.map(fn user ->
      %{
        id: user.userid,
        username: decode(user.username),
        email: blank(user.email),
        confirmed: true,
        created_at: time(user.joindate),
        last_seen_at: time(user.lastactivity),
        website: user[:homepage]
      }
    end)
  end

  def stream(state, :groups) do
    state
    |> query(
      "SELECT usergroupid, title, description FROM #{t(state, "usergroup")} WHERE usergroupid > #{@default_groups}"
    )
    |> Enum.map(
      &%{id: &1.usergroupid, name: decode(&1.title), description: blank(&1.description)}
    )
  end

  def stream(state, :group_members) do
    "SELECT userid, usergroupid, membergroupids FROM #{t(state, "user")} WHERE userid > ? ORDER BY userid LIMIT ?"
    |> paged(state, :userid)
    |> Stream.flat_map(fn user ->
      groups = [user.usergroupid | ids(user.membergroupids)]

      for group_id <- Enum.uniq(groups),
          group_id > @default_groups,
          do: %{group_id: group_id, user_id: user.userid}
    end)
  end

  def stream(%{version: 4} = state, :categories) do
    state
    |> query("SELECT * FROM #{t(state, "forum")} ORDER BY displayorder, forumid")
    # parentlist is the forum's ancestry ("5,2,-1"): parents first.
    |> Enum.sort_by(&length(String.split(&1.parentlist, ",")))
    |> Enum.map(fn forum ->
      %{
        id: forum.forumid,
        title: decode(forum.title),
        description: blank(forum.description && Markdown.from_html(forum.description)),
        position: forum.displayorder,
        parent_id: if(forum.parentid > 0, do: forum.parentid)
      }
    end)
  end

  def stream(%{version: 5} = state, :categories) do
    Enum.map(state.channels, fn channel ->
      %{
        id: channel.nodeid,
        title: decode(channel.title),
        description: blank(channel.description && Markdown.from_html(channel.description)),
        position: channel.displayorder,
        parent_id: if(channel.parentid in state.channel_ids, do: channel.parentid),
        created_at: time(channel.publishdate)
      }
    end)
  end

  def stream(%{version: 4} = state, :uploads) do
    data = if state.attachments_dir, do: "", else: ", f.filedata"

    """
    SELECT a.attachmentid, a.userid, a.filename, a.filedataid, f.userid AS owner#{data}
    FROM #{t(state, "attachment")} a JOIN #{t(state, "filedata")} f ON f.filedataid = a.filedataid
    WHERE a.attachmentid > ? ORDER BY a.attachmentid LIMIT ?
    """
    |> paged(state, :attachmentid)
    |> Stream.map(&upload(state, &1.attachmentid, &1))
  end

  def stream(%{version: 5} = state, :uploads) do
    data = if state.attachments_dir, do: "", else: ", f.filedata"

    """
    SELECT n.nodeid, n.userid, a.filename, a.filedataid, f.userid AS owner#{data}
    FROM #{t(state, "node")} n
    JOIN #{t(state, "attach")} a ON a.nodeid = n.nodeid
    JOIN #{t(state, "filedata")} f ON f.filedataid = a.filedataid
    WHERE n.nodeid > ? ORDER BY n.nodeid LIMIT ?
    """
    |> paged(state, :nodeid)
    |> Stream.map(&upload(state, &1.nodeid, &1))
  end

  def stream(%{version: 4} = state, :topics) do
    "SELECT * FROM #{t(state, "thread")} WHERE threadid > ? AND visible = 1 AND open <> 10 ORDER BY threadid LIMIT ?"
    |> paged(state, :threadid)
    |> Stream.map(fn thread ->
      %{
        id: thread.threadid,
        category_id: thread.forumid,
        title: decode(thread.title),
        views: thread.views,
        pinned_at: if(thread.sticky == 1, do: time(thread.dateline)),
        closed_at: if(thread.open == 0, do: time(thread.lastpost)),
        created_at: time(thread.dateline)
      }
    end)
  end

  def stream(%{version: 5} = state, :topics) do
    state
    |> starters()
    |> Stream.map(fn node ->
      %{
        id: node.nodeid,
        category_id: node.parentid,
        title: decode(node.title),
        views: node[:views] || 0,
        pinned_at: if(node.sticky == 1, do: time(node.publishdate)),
        closed_at: if(node.open == 0, do: time(node.lastcontent)),
        created_at: time(node.publishdate)
      }
    end)
  end

  def stream(%{version: 4} = state, :posts) do
    """
    SELECT p.* FROM #{t(state, "post")} p
    JOIN #{t(state, "thread")} th ON th.threadid = p.threadid AND th.visible = 1 AND th.open <> 10
    WHERE (p.threadid, p.postid) > (?, ?) AND p.visible IN (1, 2)
    ORDER BY p.threadid, p.postid LIMIT ?
    """
    |> paged_by(state, :threadid, :postid)
    |> Stream.map(fn post ->
      {body, uploads} = body(state, post.pagetext, post.postid)

      %{
        id: post.postid,
        topic_id: post.threadid,
        user_id: author(post.userid, post.username),
        user_names: names(post.userid, post.username),
        body: body,
        uploads: uploads,
        created_at: time(post.dateline),
        deleted_at: if(post.visible == 2, do: time(post.dateline))
      }
    end)
  end

  def stream(%{version: 5} = state, :posts) do
    """
    SELECT n.nodeid, n.starter, n.userid, n.authorname, n.publishdate, n.unpublishdate, n.showpublished,
      n.deleteuserid, x.rawtext
    FROM #{t(state, "node")} n
    JOIN #{t(state, "text")} x ON x.nodeid = n.nodeid
    JOIN #{t(state, "node")} s ON s.nodeid = n.starter AND s.parentid IN (#{in_list(state.channel_ids)})
    WHERE (n.starter, n.nodeid) > (?, ?) AND n.contenttypeid = ? AND n.approved = 1
    ORDER BY n.starter, n.nodeid LIMIT ?
    """
    |> paged_by(state, :starter, :nodeid, [state.types["Text"]])
    |> Stream.map(fn node ->
      {body, uploads} = body(state, node.rawtext, node.nodeid)

      %{
        id: node.nodeid,
        topic_id: node.starter,
        user_id: author(node.userid, node.authorname),
        user_names: names(node.userid, node.authorname),
        body: body,
        uploads: uploads,
        created_at: time(node.publishdate),
        deleted_at:
          if(node.deleteuserid > 0, do: time(node.unpublishdate) || time(node.publishdate))
      }
    end)
  end

  # vBulletin 4: each message a conversation of its own, with its
  # recipients (each has a copy in `pm`).
  def stream(%{version: 4} = state, :conversations) do
    "SELECT * FROM #{t(state, "pmtext")} WHERE pmtextid > ? ORDER BY pmtextid LIMIT ?"
    |> paged(state, :pmtextid)
    |> Stream.map(fn pm ->
      recipients =
        state
        |> query("SELECT DISTINCT userid FROM #{t(state, "pm")} WHERE pmtextid = ?", [pm.pmtextid])
        |> Enum.map(& &1.userid)

      %{
        id: pm.pmtextid,
        title: decode(pm.title),
        user_id: pm.fromuserid,
        participant_ids: recipients,
        created_at: time(pm.dateline)
      }
    end)
  end

  def stream(%{version: 5} = state, :conversations) do
    """
    SELECT n.nodeid, n.title, n.userid, n.publishdate FROM #{t(state, "node")} n
    JOIN #{t(state, "privatemessage")} m ON m.nodeid = n.nodeid AND m.msgtype = 'message'
    WHERE n.nodeid > ? AND n.starter = n.nodeid ORDER BY n.nodeid LIMIT ?
    """
    |> paged(state, :nodeid)
    |> Stream.map(fn node ->
      recipients =
        state
        |> query("SELECT DISTINCT userid FROM #{t(state, "sentto")} WHERE nodeid = ?", [
          node.nodeid
        ])
        |> Enum.map(& &1.userid)

      %{
        id: node.nodeid,
        title: decode(node.title),
        user_id: node.userid,
        participant_ids: recipients,
        created_at: time(node.publishdate)
      }
    end)
  end

  def stream(%{version: 4} = state, :messages) do
    "SELECT * FROM #{t(state, "pmtext")} WHERE pmtextid > ? ORDER BY pmtextid LIMIT ?"
    |> paged(state, :pmtextid)
    |> Stream.map(fn pm ->
      %{
        id: pm.pmtextid,
        conversation_id: pm.pmtextid,
        user_id: pm.fromuserid,
        body: bbcode(pm.message),
        created_at: time(pm.dateline)
      }
    end)
  end

  def stream(%{version: 5} = state, :messages) do
    """
    SELECT n.nodeid, n.starter, n.userid, n.publishdate, x.rawtext FROM #{t(state, "node")} n
    JOIN #{t(state, "text")} x ON x.nodeid = n.nodeid
    JOIN #{t(state, "privatemessage")} m ON m.nodeid = n.starter AND m.msgtype = 'message'
    WHERE n.nodeid > ? ORDER BY n.nodeid LIMIT ?
    """
    |> paged(state, :nodeid)
    |> Stream.map(fn node ->
      %{
        id: node.nodeid,
        conversation_id: node.starter,
        user_id: node.userid,
        body: bbcode(node.rawtext),
        created_at: time(node.publishdate)
      }
    end)
  end

  def stream(%{version: 4} = state, :permalinks) do
    Stream.concat([
      "SELECT threadid, title FROM #{t(state, "thread")} WHERE threadid > ? ORDER BY threadid LIMIT ?"
      |> paged(state, :threadid)
      |> Stream.flat_map(fn thread ->
        # Search-engine friendly URLs: showthread.php/10-the-title
        seo = %{
          url: "showthread.php/#{thread.threadid}-#{seo_slug(thread.title)}",
          topic_id: thread.threadid
        }

        [seo | topic_permalinks(thread.threadid)]
      end),
      "SELECT postid FROM #{t(state, "post")} WHERE postid > ? ORDER BY postid LIMIT ?"
      |> paged(state, :postid)
      |> Stream.flat_map(&post_permalinks(&1.postid)),
      state
      |> query("SELECT forumid FROM #{t(state, "forum")}")
      |> Enum.map(&%{url: "forumdisplay.php?f=#{&1.forumid}", category_id: &1.forumid}),
      user_permalinks(state)
    ])
  end

  def stream(%{version: 5} = state, :permalinks) do
    Stream.concat([
      state |> starters() |> Stream.flat_map(&topic_permalinks(&1.nodeid)),
      Enum.map(state.channel_ids, &%{url: "forumdisplay.php?f=#{&1}", category_id: &1}),
      user_permalinks(state)
    ])
  end

  def stream(_state, _kind), do: []

  ## Helpers

  # vBulletin 5's threads: published text nodes starting a thread in a forum channel.
  defp starters(state) do
    """
    SELECT n.* FROM #{t(state, "node")} n
    WHERE n.nodeid > ? AND n.starter = n.nodeid AND n.contenttypeid = ? AND n.approved = 1
      AND n.parentid IN (#{in_list(state.channel_ids)})
    ORDER BY n.nodeid LIMIT ?
    """
    |> paged_by(state, :nodeid, [state.types["Text"]])
  end

  defp topic_permalinks(id),
    do: [
      %{url: "showthread.php?t=#{id}", topic_id: id},
      %{url: "showthread.php/#{id}", topic_id: id}
    ]

  defp seo_slug(title) do
    title
    |> decode()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp post_permalinks(id),
    do: [
      %{url: "showthread.php?p=#{id}", post_id: id},
      %{url: "showpost.php?p=#{id}", post_id: id}
    ]

  defp user_permalinks(state) do
    "SELECT userid FROM #{t(state, "user")} WHERE userid > ? ORDER BY userid LIMIT ?"
    |> paged(state, :userid)
    |> Stream.map(&%{url: "member.php?u=#{&1.userid}", user_id: &1.userid})
  end

  # Guests (user id 0) posted under a name of their own: a placeholder per name.
  defp author(0, name) when name not in [nil, ""], do: "guest:" <> name
  defp author(0, _name), do: nil
  defp author(user_id, _name), do: user_id

  defp names(0, name) when name not in [nil, ""], do: %{("guest:" <> name) => decode(name)}
  defp names(_user_id, _name), do: nil

  defp upload(state, id, attachment) do
    file =
      if state.attachments_dir do
        digits = attachment.owner |> Integer.to_string() |> String.graphemes()

        %{
          path: Path.join([state.attachments_dir | digits] ++ ["#{attachment.filedataid}.attach"])
        }
      else
        %{data: attachment.filedata}
      end

    Map.merge(file, %{id: id, user_id: attachment.userid, filename: decode(attachment.filename)})
  end

  # The post's text as Markdown, and its attachments: inline where
  # `[ATTACH]` places them, else at the end.
  defp body(state, text, post_id) do
    attachments = attachments(state, post_id)

    markdown =
      String.replace(text || "", ~r/\[ATTACH(?:=[^\]]*)?\](.*?)\[\/ATTACH\]/is, fn match ->
        [_, inner] = Regex.run(~r/\[ATTACH(?:=[^\]]*)?\](.*?)\[\/ATTACH\]/is, match)
        attachment_link(attachments, inner)
      end)

    markdown = bbcode(markdown)

    uploads =
      for %{id: id} <- attachments do
        ref = "vbulletin-attachment:#{id}"
        {if(String.contains?(markdown, ref), do: ref), id}
      end

    {markdown, uploads}
  end

  defp attachments(%{version: 4} = state, post_id) do
    state
    |> query(
      "SELECT attachmentid AS id, filename FROM #{t(state, "attachment")} WHERE contentid = ?",
      [post_id]
    )
  end

  defp attachments(%{version: 5} = state, post_id) do
    state
    |> query(
      "SELECT n.nodeid AS id, a.filename FROM #{t(state, "node")} n JOIN #{t(state, "attach")} a ON a.nodeid = n.nodeid WHERE n.parentid = ?",
      [post_id]
    )
  end

  # `[ATTACH]123[/ATTACH]`, `[ATTACH]n123[/ATTACH]` or vBulletin 5's JSON
  # `{"data-attachmentid":123,...}`.
  defp attachment_link(attachments, inner) do
    id =
      case Regex.run(~r/(?:"data-attachmentid":"?|^n?)(\d+)/, inner) do
        [_, id] -> String.to_integer(id)
        nil -> nil
      end

    case Enum.find(attachments, &(&1.id == id)) do
      nil ->
        ""

      %{filename: filename} ->
        name = decode(filename)

        if String.downcase(Path.extname(filename)) in @images,
          do: "![#{name}](vbulletin-attachment:#{id})",
          else: "[#{name}](vbulletin-attachment:#{id})"
    end
  end

  @doc "vBulletin's BBCode as Markdown: its own tags made standard first."
  def bbcode(nil), do: ""

  def bbcode(text) do
    text
    # [QUOTE=name;123] => [quote=name]
    |> String.replace(~r/\[quote=([^\];]+);[^\]]*\]/i, "[quote=\\1]")
    |> String.replace(~r/\[(\/?)(?:php|html)\]/i, "[\\1code]")
    |> String.replace(
      ~r/\[(?:font|highlight|indent|left|center|right)(?:=[^\]]*)?\]|\[\/(?:font|highlight|indent|left|center|right)\]/i,
      ""
    )
    |> String.replace(~r/\[(\/?)noparse\]/i, "")
    |> Markdown.from_bbcode()
  end

  defp ids(nil), do: []

  defp ids(list) do
    for id <- String.split(list, ",", trim: true),
        {n, ""} <- [Integer.parse(String.trim(id))],
        do: n
  end

  defp in_list([]), do: "NULL"
  defp in_list(ids), do: Enum.map_join(ids, ",", &Integer.to_string/1)

  defp decode(text), do: Markdown.decode_entities(text)

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  defp time(seconds) when is_integer(seconds) and seconds > 0, do: DateTime.from_unix!(seconds)
  defp time(_seconds), do: nil

  defp t(state, table), do: state.prefix <> table

  defp query(state, sql, params \\ []), do: MySQL.query(state.conn, sql, params)

  defp paged(sql, state, key), do: MySQL.paged(state.conn, sql, key)

  # Paged by two keys (`(a, b) > (?, ?)`), with `params` after them.
  defp paged_by(sql, state, first, second, params) do
    FireflyImport.SQL.paged(fn last, page ->
      keys = if last, do: [Map.fetch!(last, first), Map.fetch!(last, second)], else: [0, 0]
      query(state, sql, keys ++ params ++ [page])
    end)
  end

  defp paged_by(sql, state, key, params) when is_list(params) do
    FireflyImport.SQL.paged(fn last, page ->
      query(state, sql, [if(last, do: Map.fetch!(last, key), else: 0)] ++ params ++ [page])
    end)
  end

  defp paged_by(sql, state, first, second), do: paged_by(sql, state, first, second, [])
end
