defmodule FireflyImport.Sources.PhpBB do
  @moduledoc """
  Imports a phpBB 3.x forum from its MySQL (or MariaDB) database. Options:

    * `--source-url mysql://user:password@host/phpbb` (required)
    * `--table-prefix` (default `phpbb_`)
    * `--files-dir`: phpBB's `files/` directory, for attachments (else
      they aren't imported)

  What it imports: users (not bots or guests; passwords aren't, so they
  reset theirs), their groups (not the built-in ones), categories and
  forums as categories and subcategories (links left out), topics (stickies
  and announcements pinned, locked ones closed, moved-topic shadows and
  unapproved ones left out), posts with their BBCode as Markdown (phpBB
  3.0/3.1's `:uid` markers and 3.2+'s stored XML both), deleted posts as
  deleted, polls, topic bookmarks (on the first post), private messages
  (each thread of replies a conversation), attachments (inline where the
  post placed them, else at the end), and permalinks for `viewtopic.php`
  (`t=`, `p=`), `viewforum.php` and `memberlist.php` URLs.
  """

  @behaviour FireflyImport.Source

  alias FireflyImport.{Markdown, MySQL}

  # User types: 2 is bots and the guest account.
  @ignored_user 2
  # Group types: 3 is the built-in groups (guests, registered, admins...).
  @special_group 3
  # Forum types: 0 a category, 1 a forum, 2 a link.
  @link_forum 2
  # Topic types: 1 sticky, 2 announcement, 3 global announcement.
  @pinned_topics [1, 2, 3]

  @impl true
  def name, do: "phpbb"

  @impl true
  def switches, do: [source_url: :string, table_prefix: :string, files_dir: :string]

  @impl true
  def usage do
    """
      --source-url URL      the phpBB database (mysql://user:password@host/db)
      --table-prefix PREFIX its tables' prefix (default phpbb_)
      --files-dir DIR       its files/ directory, for attachments
    """
  end

  @impl true
  def open(opts) do
    prefix = opts[:table_prefix] || "phpbb_"

    with {:ok, conn} <- MySQL.connect(opts[:source_url], prefix <> "posts") do
      {:ok,
       %{
         conn: conn,
         prefix: prefix,
         files_dir: opts[:files_dir],
         # phpBB 3.1+ keeps deleted posts (visibility 2); 3.0 has none.
         visibility?: MySQL.column?(conn, prefix <> "posts", "post_visibility")
       }}
    end
  end

  @impl true
  def close(%{conn: conn}), do: MySQL.close(conn)

  @impl true
  def stream(state, :users) do
    "SELECT * FROM #{t(state, "users")} WHERE user_id > ? AND user_type <> #{@ignored_user} ORDER BY user_id LIMIT ?"
    |> paged(state, :user_id)
    |> Stream.map(fn user ->
      %{
        id: user.user_id,
        username: decode(user.username),
        email: blank(user.user_email),
        confirmed: user.user_type == 0,
        created_at: time(user.user_regdate),
        last_seen_at: time(user.user_lastvisit),
        website: user[:user_website],
        location: user[:user_from] && decode(user.user_from),
        avatar: avatar(state, user)
      }
    end)
  end

  def stream(state, :groups) do
    state
    |> query(
      "SELECT * FROM #{t(state, "groups")} WHERE group_type <> #{@special_group} ORDER BY group_id"
    )
    |> Enum.map(
      &%{
        id: &1.group_id,
        name: decode(&1.group_name),
        description: text(&1.group_desc, &1.group_desc_uid)
      }
    )
  end

  def stream(state, :group_members) do
    state
    |> query("""
    SELECT ug.group_id, ug.user_id, ug.group_leader FROM #{t(state, "user_group")} ug
    JOIN #{t(state, "groups")} g ON g.group_id = ug.group_id AND g.group_type <> #{@special_group}
    WHERE ug.user_pending = 0
    """)
    |> Enum.map(&%{group_id: &1.group_id, user_id: &1.user_id, owner: &1.group_leader == 1})
  end

  # Ordered by the nested set's left edge: parents before children.
  def stream(state, :categories) do
    state
    |> query(
      "SELECT * FROM #{t(state, "forums")} WHERE forum_type <> #{@link_forum} ORDER BY left_id"
    )
    |> Enum.with_index()
    |> Enum.map(fn {forum, position} ->
      %{
        id: forum.forum_id,
        title: decode(forum.forum_name),
        description: text(forum.forum_desc, forum.forum_desc_uid),
        parent_id: if(forum.parent_id > 0, do: forum.parent_id),
        position: position
      }
    end)
  end

  def stream(%{files_dir: nil}, :uploads), do: []

  def stream(state, :uploads) do
    "SELECT * FROM #{t(state, "attachments")} WHERE attach_id > ? ORDER BY attach_id LIMIT ?"
    |> paged(state, :attach_id)
    |> Stream.map(
      &%{
        id: &1.attach_id,
        user_id: &1.poster_id,
        filename: decode(&1.real_filename),
        path: Path.join(state.files_dir, Path.basename(&1.physical_filename))
      }
    )
  end

  def stream(state, :topics) do
    """
    SELECT * FROM #{t(state, "topics")}
    WHERE topic_id > ? AND topic_moved_id = 0 AND #{visible(state, "topic")}
    ORDER BY topic_id LIMIT ?
    """
    |> paged(state, :topic_id)
    |> Stream.map(fn topic ->
      %{
        id: topic.topic_id,
        category_id: topic.forum_id,
        title: decode(topic.topic_title),
        views: topic.topic_views,
        pinned_at: if(topic.topic_type in @pinned_topics, do: time(topic.topic_time)),
        closed_at: if(topic.topic_status == 1, do: time(topic.topic_last_post_time)),
        created_at: time(topic.topic_time)
      }
    end)
  end

  def stream(state, :posts) do
    """
    SELECT p.* FROM #{t(state, "posts")} p
    JOIN #{t(state, "topics")} t ON t.topic_id = p.topic_id AND t.topic_moved_id = 0 AND #{visible(state, "t.topic")}
    WHERE (p.topic_id, p.post_id) > (?, ?) AND (#{visible(state, "p.post")} OR #{deleted(state)})
    ORDER BY p.topic_id, p.post_id LIMIT ?
    """
    |> paged_by_topic(state)
    |> Stream.map(fn post ->
      {body, uploads} = body(state, post.post_text, post.bbcode_uid, post.post_id, 0)
      {user_id, user_names} = author(post)

      %{
        id: post.post_id,
        topic_id: post.topic_id,
        user_id: user_id,
        user_names: user_names,
        body: body,
        uploads: uploads,
        created_at: time(post.post_time),
        edited_at: if(post.post_edit_time > 0, do: time(post.post_edit_time)),
        deleted_at: if(deleted?(state, post), do: time(post.post_time))
      }
    end)
  end

  def stream(state, :bookmarks) do
    state
    |> query("""
    SELECT b.user_id, t.topic_first_post_id FROM #{t(state, "bookmarks")} b
    JOIN #{t(state, "topics")} t ON t.topic_id = b.topic_id
    """)
    |> Enum.map(&%{post_id: &1.topic_first_post_id, user_id: &1.user_id})
  end

  def stream(state, :polls) do
    state
    |> query(
      "SELECT * FROM #{t(state, "topics")} WHERE poll_start > 0 AND topic_moved_id = 0 ORDER BY topic_id"
    )
    |> Enum.map(fn topic ->
      options =
        state
        |> query(
          "SELECT poll_option_id, poll_option_text FROM #{t(state, "poll_options")} WHERE topic_id = ? ORDER BY poll_option_id",
          [topic.topic_id]
        )
        |> Enum.map(&{&1.poll_option_id, decode(&1.poll_option_text)})

      votes =
        state
        |> query(
          "SELECT vote_user_id, poll_option_id FROM #{t(state, "poll_votes")} WHERE topic_id = ?",
          [
            topic.topic_id
          ]
        )
        |> Enum.map(&{&1.vote_user_id, &1.poll_option_id, nil})

      %{
        id: topic.topic_id,
        post_id: topic.topic_first_post_id,
        kind: if(topic.poll_max_options > 1, do: "multiple", else: "single"),
        min_choices: if(topic.poll_max_options > 1, do: 1),
        max_choices:
          if(topic.poll_max_options > 1, do: min(topic.poll_max_options, length(options))),
        close_at: if(topic.poll_length > 0, do: time(topic.poll_start + topic.poll_length)),
        options: options,
        votes: votes,
        created_at: time(topic.poll_start)
      }
    end)
  end

  # A private message thread: the first message and its replies (root_level).
  def stream(state, :conversations) do
    "SELECT * FROM #{t(state, "privmsgs")} WHERE msg_id > ? AND root_level = 0 ORDER BY msg_id LIMIT ?"
    |> paged(state, :msg_id)
    |> Stream.map(fn message ->
      recipients =
        state
        |> query(
          """
          SELECT DISTINCT user_id FROM #{t(state, "privmsgs_to")}
          WHERE msg_id = ? OR msg_id IN (SELECT msg_id FROM #{t(state, "privmsgs")} WHERE root_level = ?)
          """,
          [message.msg_id, message.msg_id]
        )
        |> Enum.map(& &1.user_id)

      %{
        id: message.msg_id,
        title: decode(message.message_subject),
        user_id: message.author_id,
        participant_ids: recipients,
        created_at: time(message.message_time)
      }
    end)
  end

  def stream(state, :messages) do
    "SELECT * FROM #{t(state, "privmsgs")} WHERE msg_id > ? ORDER BY msg_id LIMIT ?"
    |> paged(state, :msg_id)
    |> Stream.map(fn message ->
      {body, uploads} = body(state, message.message_text, message.bbcode_uid, message.msg_id, 1)

      %{
        id: message.msg_id,
        conversation_id: if(message.root_level > 0, do: message.root_level, else: message.msg_id),
        user_id: message.author_id,
        body: body,
        uploads: uploads,
        created_at: time(message.message_time)
      }
    end)
  end

  def stream(state, :permalinks) do
    Stream.concat([
      "SELECT topic_id FROM #{t(state, "topics")} WHERE topic_id > ? ORDER BY topic_id LIMIT ?"
      |> paged(state, :topic_id)
      |> Stream.map(&%{url: "viewtopic.php?t=#{&1.topic_id}", topic_id: &1.topic_id}),
      "SELECT post_id FROM #{t(state, "posts")} WHERE post_id > ? ORDER BY post_id LIMIT ?"
      |> paged(state, :post_id)
      |> Stream.map(&%{url: "viewtopic.php?p=#{&1.post_id}", post_id: &1.post_id}),
      state
      |> query("SELECT forum_id FROM #{t(state, "forums")}")
      |> Enum.map(&%{url: "viewforum.php?f=#{&1.forum_id}", category_id: &1.forum_id}),
      "SELECT user_id FROM #{t(state, "users")} WHERE user_id > ? ORDER BY user_id LIMIT ?"
      |> paged(state, :user_id)
      |> Stream.map(&%{url: "memberlist.php?u=#{&1.user_id}", user_id: &1.user_id})
    ])
  end

  def stream(_state, _kind), do: []

  ## Users

  # Guests (user id 1) posted under a name of their own: a placeholder of
  # that name, one per name.
  defp author(%{poster_id: 1, post_username: name}) when name not in [nil, ""],
    do: {"guest:" <> name, %{("guest:" <> name) => decode(name)}}

  defp author(%{poster_id: 1}), do: {nil, nil}
  defp author(%{poster_id: id}), do: {id, nil}

  # Uploaded avatars, as phpBB names them in files/ (its avatar salt is in
  # its config table).
  defp avatar(%{files_dir: nil}, _user), do: nil

  defp avatar(state, %{user_avatar_type: type, user_avatar: avatar} = user)
       when type in ["avatar.driver.upload", "1", 1] and avatar not in [nil, ""] do
    with [%{config_value: salt}] <-
           query(
             state,
             "SELECT config_value FROM #{t(state, "config")} WHERE config_name = 'avatar_salt'"
           ),
         [%{config_value: path}] <-
           query(
             state,
             "SELECT config_value FROM #{t(state, "config")} WHERE config_name = 'avatar_path'"
           ) do
      file = "#{salt}_#{user.user_id}#{Path.extname(avatar)}"
      %{filename: Path.basename(avatar), path: Path.join([state.files_dir, "..", path, file])}
    else
      _ -> nil
    end
  end

  defp avatar(_state, _user), do: nil

  ## Posts

  defp visible(%{visibility?: true}, field), do: "#{field}_visibility = 1"
  defp visible(_state, field), do: "#{field}_approved = 1"

  defp deleted(%{visibility?: true}), do: "p.post_visibility = 2"
  defp deleted(_state), do: "FALSE"

  defp deleted?(%{visibility?: true}, post), do: post.post_visibility == 2
  defp deleted?(_state, _post), do: false

  # The post's text as Markdown and its attachments: where the text shows
  # one (`[attachment=N]`, N counting the post's attachments, newest first),
  # a reference to it, the rest at the end.
  defp body(state, text, uid, id, in_message) do
    attachments =
      if state.files_dir,
        do:
          query(
            state,
            "SELECT attach_id, real_filename FROM #{t(state, "attachments")} WHERE post_msg_id = ? AND in_message = ? ORDER BY attach_id DESC",
            [id, in_message]
          ),
        else: []

    markdown =
      text
      |> to_bbcode(uid)
      |> String.replace(~r/\[attachment=(\d+)\](.*?)\[\/attachment\]/s, fn match ->
        [_, index, name] = Regex.run(~r/\[attachment=(\d+)\](.*?)\[\/attachment\]/s, match)

        case Enum.at(attachments, String.to_integer(index)) do
          nil -> name
          attachment -> attachment_link(attachment, name)
        end
      end)
      |> Markdown.from_bbcode()

    uploads =
      Enum.map(attachments, fn %{attach_id: attach_id} ->
        ref = "phpbb-attachment:#{attach_id}"
        {if(String.contains?(markdown, ref), do: ref), attach_id}
      end)

    {markdown, uploads}
  end

  defp attachment_link(%{attach_id: id, real_filename: filename}, name) do
    name = if name == "", do: decode(filename), else: name

    image? = String.downcase(Path.extname(filename)) in ~w(.png .jpg .jpeg .gif .webp)

    if image?, do: "![#{name}](phpbb-attachment:#{id})", else: "[#{name}](phpbb-attachment:#{id})"
  end

  @doc """
  phpBB's stored post text as plain BBCode: 3.2+ stores it as XML with the
  original markup in it; 3.0 and 3.1 add the post's `uid` to each tag and
  keep smilies and links as HTML. Either way it's HTML-escaped.
  """
  def to_bbcode(nil, _uid), do: ""

  def to_bbcode(<<"<", tag, ">", _::binary>> = xml, _uid) when tag in [?r, ?t] do
    xml
    |> String.replace(~r{<br\s*/?>}, "\n")
    |> String.replace(~r{<[^>]+>}, "")
    |> decode()
  end

  def to_bbcode(text, uid) do
    text
    |> strip_uid(uid)
    # Smilies: <!-- s:) --><img ... alt=":)" ... /><!-- s:) -->
    |> String.replace(~r{<!-- s(.*?) -->.*?<!-- s.*? -->}s, "\\1")
    # Links made from bare URLs and emails.
    |> String.replace(
      ~r{<!-- [mlwe] --><a [^>]*href="([^"]*)"[^>]*>.*?</a><!-- [mlwe] -->}s,
      "\\1"
    )
    |> String.replace(~r{<!-- ia\d+ -->(.*?)<!-- ia\d+ -->}s, "\\1")
    |> String.replace("<br />", "\n")
    |> decode()
  end

  defp strip_uid(text, uid) when uid in [nil, ""], do: text

  defp strip_uid(text, uid) do
    text
    |> String.replace(":" <> uid, "")
    |> String.replace(~r{\[/\*:m\]}, "")
    |> String.replace(~r{\[/list:[uo]\]}, "[/list]")
  end

  # A description: BBCode as Markdown.
  defp text(text, uid), do: text |> to_bbcode(uid) |> Markdown.from_bbcode() |> blank()

  ## Helpers

  defp decode(text), do: Markdown.decode_entities(text)

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  defp time(seconds) when is_integer(seconds) and seconds > 0, do: DateTime.from_unix!(seconds)
  defp time(_seconds), do: nil

  defp t(state, table), do: state.prefix <> table

  defp query(state, sql, params \\ []), do: MySQL.query(state.conn, sql, params)

  defp paged(sql, state, key), do: MySQL.paged(state.conn, sql, key)

  defp paged_by_topic(sql, state) do
    FireflyImport.SQL.paged(fn last, page ->
      {topic_id, post_id} = if last, do: {last.topic_id, last.post_id}, else: {0, 0}
      query(state, sql, [topic_id, post_id, page])
    end)
  end
end
