defmodule Firefly.Import.Writer do
  @moduledoc """
  Writes imported records (see `Firefly.Import`): users, groups,
  categories, tags, threads, posts, likes, bookmarks, polls, accepted
  answers, private messages, chat channels and messages, reactions and
  uploads, with their original authors and timestamps.

  It writes rows directly, the way they'd be after the original site's
  history happened here: no notifications, emails, rate limits, spam checks
  or plugin hooks, and no length limits (the old site accepted the content).
  References are local ids (the importer's pipeline maps the source's ids);
  timestamps may be `DateTime`s or `NaiveDateTime`s (UTC).

  Imported users get no password: they log in by resetting it (with an
  email address), a magic link or single sign-on (`identities`).
  """

  import Ecto.Query

  alias Firefly.{Repo, Uploads}
  alias Firefly.Accounts.User
  alias Firefly.Chat
  alias Firefly.Discussion.{Category, Poll, Post, PostLike, Tag, TagGroup, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Messaging.{Conversation, ConversationParticipant, Message}
  alias Firefly.Uploads.Upload

  @max_username 32

  ## Users and groups

  @doc """
  Imports a user, or finds who they already are here: the account linked to
  one of their `identities` (`%{provider:, uid:, info:}`), else the one with
  the same `email` (any case). Otherwise creates one with their `username`
  (made valid and unique: letters, digits, `-` and `_`), `name`, `email`
  (optional), profile (`bio`, `website`, `location`), `trust_level`,
  `suspended_until`/`suspend_reason`, `silenced_until` and `created_at`,
  `last_seen_at`; `confirmed: true` marks their email as confirmed.
  Returns `{:ok, user}`.
  """
  def user(attrs) do
    identities = attrs[:identities] || []

    case existing_user(identities, attrs[:email]) do
      %User{} = user ->
        link_identities(user, identities)
        {:ok, user}

      nil ->
        with {:ok, user} <- insert_user(attrs) do
          link_identities(user, identities)
          {:ok, user}
        end
    end
  end

  defp existing_user(identities, email) do
    Enum.find_value(identities, fn %{provider: provider, uid: uid} ->
      Repo.one(
        from(u in User,
          join: i in "user_identities",
          on: i.user_id == u.id,
          where: i.provider == ^provider and i.uid == ^to_string(uid)
        )
      )
    end) || by_email(email)
  end

  defp by_email(email) when is_binary(email) and email != "" do
    Repo.one(
      from(u in User,
        where: fragment("lower(?)", u.email) == ^String.downcase(email),
        order_by: u.id,
        limit: 1
      )
    )
  end

  defp by_email(_email), do: nil

  defp insert_user(attrs) do
    created_at = naive(attrs[:created_at]) || now()
    email = blank_to_nil(attrs[:email])
    username = unique_username(attrs[:username] || attrs[:name] || "user")

    Repo.insert(%User{
      username: username,
      name: blank_to_nil(attrs[:name]) || blank_to_nil(attrs[:username]) || username,
      email: email,
      api_token: Ecto.UUID.generate(),
      confirmed_at: confirmed_at(email, attrs[:confirmed], created_at),
      bio: blank_to_nil(attrs[:bio]),
      website: web_url(attrs[:website]),
      location: truncate(blank_to_nil(attrs[:location]), 100),
      trust_level: attrs[:trust_level] || 1,
      suspended_until: second(attrs[:suspended_until]),
      suspend_reason: if(attrs[:suspended_until], do: attrs[:suspend_reason]),
      silenced_until: second(attrs[:silenced_until]),
      last_seen_at: second(attrs[:last_seen_at]),
      inserted_at: created_at,
      updated_at: naive(attrs[:updated_at]) || created_at
    })
  end

  # Their email counts as confirmed when the source says it was.
  defp confirmed_at(email, true, created_at) when is_binary(email), do: second(created_at)
  defp confirmed_at(_email, _confirmed, _created_at), do: nil

  # Their logins (one per provider; a login linked to someone else stays theirs).
  defp link_identities(user, identities) do
    now = now()

    for %{provider: provider, uid: uid} = identity <- identities do
      Repo.insert_all(
        "user_identities",
        [
          %{
            user_id: user.id,
            provider: provider,
            uid: to_string(uid),
            info: identity[:info] || %{},
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )
    end

    :ok
  end

  @doc """
  A placeholder account for an author the source doesn't describe (deleted,
  or only known by name): no email, so nobody can log in as it.
  """
  def placeholder_user(username, created_at \\ nil),
    do: insert_user(%{username: username, created_at: created_at, trust_level: 0})

  @doc """
  `name` made a valid username (letters, digits, `-` and `_`, 2 to 32
  characters) that nobody has, in any case: `name`, else `name2`, `name3`...
  """
  def unique_username(name) do
    base =
      name
      |> to_string()
      |> String.normalize(:nfd)
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @max_username)

    base =
      if String.length(base) < 2 or User.reserved_username?(base), do: "user_" <> base, else: base

    first_free(
      fn
        1 -> base
        n -> String.slice(base, 0, @max_username - String.length("#{n}")) <> "#{n}"
      end,
      &username_taken?/1
    )
  end

  defp username_taken?(username) do
    Repo.exists?(
      from(u in User, where: fragment("lower(?)", u.username) == ^String.downcase(username))
    )
  end

  @doc "Sets the user's avatar to the image `data` (named `filename`)."
  def avatar(%User{} = user, data, filename) do
    with {:ok, upload} <- Uploads.import(user, data, filename, variant: "avatar") do
      user |> Ecto.Changeset.change(avatar_upload_id: upload.id) |> Repo.update()
    end
  end

  @doc """
  Imports a group: the existing group of that `name` (any case), or a new
  one with its `description`. Returns `{:ok, role}`.
  """
  def group(attrs) do
    name = attrs.name |> to_string() |> String.trim() |> String.slice(0, 40)

    case Repo.one(from(r in Role, where: fragment("lower(?)", r.name) == ^String.downcase(name))) do
      %Role{} = role ->
        {:ok, role}

      nil ->
        created_at = naive(attrs[:created_at]) || now()

        %Role{inserted_at: created_at, updated_at: created_at}
        |> Role.changeset(%{name: name})
        |> Ecto.Changeset.put_change(:description, blank_to_nil(attrs[:description]))
        |> Ecto.Changeset.put_change(:visibility, attrs[:visibility] || "public")
        |> Repo.insert()
    end
  end

  @doc "Adds the user to the group (an `owner` of it, if so), unless they're in it."
  def group_member(role_id, user_id, owner? \\ false) do
    if Repo.exists?(
         from(m in RoleMembership, where: m.role_id == ^role_id and m.user_id == ^user_id)
       ) do
      {:ok, :exists}
    else
      Repo.insert(%RoleMembership{role_id: role_id, user_id: user_id, owner: owner? == true})
    end
  end

  ## Categories and tags

  @doc """
  Imports a category: `title`, `description`, `color` (`#rrggbb`),
  `position`, `parent_id`, `allow_accepted_answers`, and `role_ids`, the
  groups it's restricted to. Firefly nests categories one level deep, so a
  category under a subcategory goes under that subcategory's parent.
  """
  def category(attrs) do
    created_at = naive(attrs[:created_at]) || now()

    params = %{
      title: attrs.title,
      description: truncate(blank_to_nil(attrs[:description]), 1000),
      color: color(attrs[:color]),
      position: max(attrs[:position] || 0, 0),
      parent_id: top_level_parent(attrs[:parent_id]),
      allow_accepted_answers: attrs[:allow_accepted_answers] == true
    }

    roles = Repo.all(from(r in Role, where: r.id in ^(attrs[:role_ids] || [])))

    %Category{inserted_at: created_at, updated_at: created_at}
    |> Category.changeset(params)
    |> Ecto.Changeset.put_assoc(:roles, roles)
    |> Repo.insert()
  end

  defp top_level_parent(nil), do: nil

  defp top_level_parent(id) do
    case Repo.get(Category, id) do
      %Category{parent_id: nil} -> id
      %Category{parent_id: parent_id} -> parent_id
      nil -> nil
    end
  end

  defp color("#" <> _ = color), do: if(color =~ ~r/^#[0-9a-fA-F]{6}$/, do: color)
  defp color(hex) when is_binary(hex), do: color("#" <> hex)
  defp color(_), do: nil

  @doc """
  The tag named `name` (made a valid tag name), created if new, in the tag
  group `group` (a name, created if new) when given. `{:ok, nil}` when
  nothing of the name is left.
  """
  def tag(name, group \\ nil) do
    case tag_name(name) do
      "" ->
        {:ok, nil}

      name ->
        Repo.insert(%Tag{name: name}, on_conflict: :nothing)
        tag = Repo.get_by!(Tag, name: name)
        put_tag_group(tag, group)
    end
  end

  defp put_tag_group(tag, group) when group in [nil, ""], do: {:ok, tag}

  defp put_tag_group(%Tag{group_id: nil} = tag, group) do
    name = group |> String.trim() |> String.slice(0, 50)
    Repo.insert(%TagGroup{name: name}, on_conflict: :nothing)
    tag_group = Repo.get_by!(TagGroup, name: name)
    tag |> Ecto.Changeset.change(group_id: tag_group.id) |> Repo.update()
  end

  defp put_tag_group(tag, _group), do: {:ok, tag}

  @doc "`name` made a tag name: lowercase letters, digits and inner dashes, 30 at most."
  def tag_name(name) do
    name
    |> to_string()
    |> String.normalize(:nfd)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 30)
    |> String.trim("-")
  end

  ## Threads and posts

  @doc """
  Imports a thread (without posts: add them with `post/1`, the first one
  first): `title`, `category_id`, `tag_ids`, `views`, `pinned_at`,
  `closed_at`, `archived_at`, `created_at` and `updated_at`.
  """
  def thread(attrs) do
    created_at = naive(attrs[:created_at]) || now()
    tags = Repo.all(from(t in Tag, where: t.id in ^(attrs[:tag_ids] || [])))

    %Thread{
      inserted_at: created_at,
      updated_at: naive(attrs[:updated_at]) || created_at,
      views: attrs[:views] || 0,
      pinned_at: second(attrs[:pinned_at]),
      closed_at: second(attrs[:closed_at]),
      archived_at: second(attrs[:archived_at])
    }
    |> Thread.changeset(%{
      title: String.slice(to_string(attrs.title), 0, 255),
      category_id: attrs.category_id
    })
    |> Ecto.Changeset.put_assoc(:tags, tags)
    |> Repo.insert()
  end

  @doc """
  Imports a post: `body` (Markdown), `thread_id`, `user_id`, `created_at`,
  `updated_at`, `edited_at`, `deleted_at`, `wiki` and `upload_ids`, the
  uploads it shows (attached to it).
  """
  def post(attrs) do
    created_at = naive(attrs[:created_at]) || now()

    with {:ok, post} <-
           Repo.insert(%Post{
             body: attrs.body,
             thread_id: attrs.thread_id,
             user_id: attrs.user_id,
             wiki: attrs[:wiki] == true,
             edited_at: naive(attrs[:edited_at]),
             deleted_at: second(attrs[:deleted_at]),
             inserted_at: created_at,
             updated_at: naive(attrs[:updated_at]) || created_at
           }) do
      attach(attrs[:upload_ids], "post", [post_id: post.id], created_at)
      {:ok, post}
    end
  end

  @doc "A like of the post by the user (once)."
  def like(post_id, user_id, created_at \\ nil) do
    Repo.insert(
      %PostLike{post_id: post_id, user_id: user_id, inserted_at: naive(created_at) || now()},
      on_conflict: :nothing
    )
  end

  @doc "A bookmark of the post by the user (once), with an optional `note`."
  def bookmark(post_id, user_id, created_at \\ nil, note \\ nil) do
    at = naive(created_at) || now()

    {count, _} =
      Repo.insert_all(
        "forums_bookmarks",
        [
          %{
            post_id: post_id,
            user_id: user_id,
            note: truncate(blank_to_nil(note), 500),
            inserted_at: at,
            updated_at: at
          }
        ],
        on_conflict: :nothing
      )

    {:ok, count}
  end

  @doc """
  Imports a post's poll: `post_id`, `kind` (`single`, `multiple` or
  `ranked`), `min_choices`, `max_choices`, `results` (`always`, `voted` or
  `closed`), `public`, `close_at`, `closed_at`, `options` (`[{key, text}]`,
  in order) and `votes` (`[{user_id, option_key, rank}]`, rank nil but in
  ranked polls).
  """
  def poll(attrs) do
    created_at = naive(attrs[:created_at]) || now()

    with {:ok, poll} <-
           Repo.insert(%Poll{
             post_id: attrs.post_id,
             kind: attrs[:kind] || "single",
             min_choices: attrs[:min_choices],
             max_choices: attrs[:max_choices],
             results: attrs[:results] || "always",
             public: attrs[:public] == true,
             close_at: second(attrs[:close_at]),
             closed_at: second(attrs[:closed_at]),
             inserted_at: created_at,
             updated_at: created_at
           }) do
      option_ids =
        attrs.options
        |> Enum.with_index()
        |> Map.new(fn {{key, text}, position} ->
          {1, [%{id: id}]} =
            Repo.insert_all(
              "forums_poll_options",
              [%{poll_id: poll.id, position: position, text: String.slice(text, 0, 200)}],
              returning: [:id]
            )

          {key, id}
        end)

      votes =
        for {user_id, key, rank} <- attrs[:votes] || [], option_id = option_ids[key] do
          %{
            poll_id: poll.id,
            option_id: option_id,
            user_id: user_id,
            rank: rank,
            inserted_at: created_at
          }
        end

      Repo.insert_all("forums_poll_votes", votes, on_conflict: :nothing)
      {:ok, poll}
    end
  end

  @doc "Marks the post as its thread's accepted answer."
  def solved(thread_id, post_id) do
    {count, _} =
      Repo.update_all(from(t in Thread, where: t.id == ^thread_id),
        set: [accepted_post_id: post_id]
      )

    {:ok, count}
  end

  ## Private messages

  @doc """
  Imports a private conversation (without messages: add them with
  `message/1`): `title`, `user_id` (who started it), `participant_ids`
  (everyone in it, them included), `role_id` (a group it was sent to) and
  `created_at`.
  """
  def conversation(attrs) do
    created_at = naive(attrs[:created_at]) || now()

    with {:ok, conversation} <-
           Repo.insert(%Conversation{
             title: String.slice(to_string(attrs.title), 0, 255),
             user_id: attrs.user_id,
             role_id: attrs[:role_id],
             last_message_at: created_at,
             inserted_at: created_at,
             updated_at: created_at
           }) do
      participants =
        for user_id <- Enum.uniq([attrs.user_id | attrs[:participant_ids] || []]) do
          %{
            conversation_id: conversation.id,
            user_id: user_id,
            inserted_at: created_at,
            updated_at: created_at
          }
        end

      Repo.insert_all(ConversationParticipant, participants, on_conflict: :nothing)
      {:ok, conversation}
    end
  end

  @doc "Imports a private message: `conversation_id`, `user_id`, `body`, `created_at`, `upload_ids`."
  def message(attrs) do
    created_at = naive(attrs[:created_at]) || now()

    with {:ok, message} <-
           Repo.insert(%Message{
             conversation_id: attrs.conversation_id,
             user_id: attrs.user_id,
             body: attrs.body,
             inserted_at: created_at,
             updated_at: created_at
           }) do
      Repo.update_all(
        from(c in Conversation,
          where: c.id == ^attrs.conversation_id,
          where: is_nil(c.last_message_at) or c.last_message_at < ^created_at
        ),
        set: [last_message_at: created_at]
      )

      attach(attrs[:upload_ids], "message", [message_id: message.id], created_at)
      {:ok, message}
    end
  end

  ## Chat

  @doc """
  Imports a chat channel: `name`, `description`, `category_id`,
  `created_by_id`, `created_at` and `member_ids` (who follow it). Its slug
  is made from the name, unique.
  """
  def chat_channel(attrs) do
    created_at = naive(attrs[:created_at]) || now()
    name = attrs.name |> to_string() |> String.trim() |> String.slice(0, 50)
    slug = name |> Chat.Channel.slugify() |> String.slice(0, 44) |> unique_slug()

    with {:ok, channel} <-
           %Chat.Channel{
             kind: "category",
             created_by_id: attrs[:created_by_id],
             inserted_at: created_at,
             updated_at: created_at
           }
           |> Chat.Channel.changeset(%{
             name: name,
             slug: slug,
             description: truncate(blank_to_nil(attrs[:description]), 500),
             category_id: attrs[:category_id]
           })
           |> Repo.insert() do
      members =
        for user_id <- Enum.uniq(attrs[:member_ids] || []) do
          %{
            channel_id: channel.id,
            user_id: user_id,
            inserted_at: created_at,
            updated_at: created_at
          }
        end

      Repo.insert_all(Chat.Membership, members, on_conflict: :nothing)
      {:ok, channel}
    end
  end

  defp unique_slug(slug) do
    slug = if slug == "", do: "channel", else: slug

    first_free(
      fn
        1 -> slug
        n -> "#{slug}-#{n}"
      end,
      &Repo.exists?(from(c in Chat.Channel, where: c.slug == ^&1))
    )
  end

  @doc """
  Imports a chat message: `channel_id`, `user_id`, `body`, `created_at`,
  `edited_at`, `deleted_at`, `upload_ids`, and `thread_root_id`, the
  message whose thread it replies in (imported before it).
  """
  def chat_message(attrs) do
    created_at = naive(attrs[:created_at]) || now()
    thread = attrs[:thread_root_id] && chat_thread(attrs.thread_root_id)

    with {:ok, message} <-
           Repo.insert(%Chat.Message{
             channel_id: attrs.channel_id,
             user_id: attrs.user_id,
             body: attrs.body,
             thread_id: thread && thread.id,
             edited_at: second(attrs[:edited_at]),
             deleted_at: second(attrs[:deleted_at]),
             inserted_at: created_at,
             updated_at: created_at
           }) do
      Repo.update_all(
        from(c in Chat.Channel,
          where: c.id == ^attrs.channel_id,
          where: is_nil(c.last_message_at) or c.last_message_at < ^created_at
        ),
        set: [last_message_at: created_at]
      )

      if thread do
        Repo.update_all(from(t in Chat.Thread, where: t.id == ^thread.id),
          set: [last_reply_at: created_at]
        )
      end

      attach(attrs[:upload_ids], "chat", [chat_message_id: message.id], created_at)
      {:ok, message}
    end
  end

  # The thread started by the message `root_id`, created (with the root
  # message in it) on its first reply.
  defp chat_thread(root_id) do
    case Repo.get_by(Chat.Thread, original_message_id: root_id) do
      %Chat.Thread{} = thread ->
        thread

      nil ->
        root = Repo.get!(Chat.Message, root_id)

        thread =
          Repo.insert!(%Chat.Thread{
            channel_id: root.channel_id,
            original_message_id: root.id,
            inserted_at: root.inserted_at,
            updated_at: root.inserted_at
          })

        Repo.update_all(from(m in Chat.Message, where: m.id == ^root.id),
          set: [thread_id: thread.id]
        )

        thread
    end
  end

  @doc "A reaction (an emoji name, e.g. `thumbsup`) to the chat message by the user (once)."
  def reaction(message_id, user_id, emoji, created_at \\ nil) do
    Repo.insert(
      %Chat.Reaction{
        message_id: message_id,
        user_id: user_id,
        emoji: String.slice(to_string(emoji), 0, 100),
        inserted_at: naive(created_at) || now()
      },
      on_conflict: :nothing
    )
  end

  ## Uploads

  @doc "Stores `data` (named `filename`) as the user's upload; `{:ok, upload}` or `{:error, message}`."
  def upload(user_id, data, filename) do
    Uploads.import(Repo.get!(User, user_id), data, filename)
  end

  @doc "The URL of the upload with that id, and the Markdown that shows it in a post."
  def upload_link(id) do
    upload = Repo.get!(Upload, id)
    {Uploads.url(upload), Uploads.markdown(upload)}
  end

  # Attaches the uploads to what shows them (the first to show one keeps it).
  defp attach(ids, _kind, _target, _at) when ids in [nil, []], do: :ok

  defp attach(ids, kind, target, at) do
    Repo.update_all(
      from(u in Upload, where: u.id in ^ids and is_nil(u.attached_to)),
      set: [attached_to: kind, attached_at: second(at)] ++ target
    )

    :ok
  end

  ## Helpers

  # The first of the candidates (`candidate.(1)`, `candidate.(2)`...) not taken.
  defp first_free(candidate, taken?) do
    1
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(candidate)
    |> Enum.find(&(not taken?.(&1)))
  end

  defp now, do: NaiveDateTime.utc_now()

  @doc false
  def naive(nil), do: nil

  def naive(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive() |> usec()

  def naive(%NaiveDateTime{} = at), do: usec(at)

  defp usec(%NaiveDateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}

  defp second(nil), do: nil

  defp second(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  defp second(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil

  defp truncate(nil, _max), do: nil
  defp truncate(value, max), do: String.slice(value, 0, max)

  # Only web links, as a profile's website (see `User.update_changeset/2`).
  defp web_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        String.slice(String.trim(url), 0, 200)

      _ ->
        nil
    end
  end

  defp web_url(_url), do: nil
end
