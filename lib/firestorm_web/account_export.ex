defmodule FirestormWeb.AccountExport do
  @moduledoc """
  A user's data as JSON, for download: their profile and preferences, posts
  (with the revisions they made to them), threads started, likes,
  notifications, private messages they sent and the conversations they're
  in, notification levels and read positions.

  Other people appear only by public username: no one else's email, name,
  messages or post bodies. (Notification bodies, which quote other people's
  posts and messages, are left out for that reason.)

  Nor does it show what the user may no longer read (see
  `FirestormWeb.Forums.Policy`): their posts and threads in a category
  they've lost access to are theirs and stay, but without the titles of
  other people's threads or of the category; notifications and levels for
  such threads and categories are left out.
  """

  import Ecto.Query

  alias FirestormWeb.Repo

  alias FirestormWeb.Forums.{
    Category,
    CategoryWatch,
    Conversation,
    ConversationParticipant,
    Message,
    Notification,
    Policy,
    Post,
    PostLike,
    PostRevision,
    Tag,
    TagWatch,
    Thread,
    ThreadRead,
    User
  }

  @profile ~w(id username name email bio website location github_uid confirmed_at inserted_at)a
  @preferences ~w(theme email_notifications allow_private_messages reply_level new_thread_level
                  hide_profile_activity hide_from_directory)a

  @doc "The export as a JSON string."
  def to_json(%User{} = user), do: user |> build() |> Jason.encode!(pretty: true)

  @doc "The export as a map."
  def build(%User{} = user) do
    user = Repo.preload(user, :roles, force: true)

    %{
      exported_at: DateTime.utc_now(:second),
      profile: Map.take(user, @profile),
      roles: Enum.map(user.roles, & &1.name),
      preferences: Map.take(user, @preferences),
      posts: posts(user),
      threads_started: threads_started(user),
      likes: likes(user),
      notifications: notifications(user),
      conversations: conversations(user),
      notification_levels: levels(user),
      read_positions: read_positions(user)
    }
  end

  defp posts(user) do
    revisions =
      PostRevision
      |> join(:inner, [r], p in Post, on: p.id == r.post_id and p.user_id == ^user.id)
      |> where([r], r.user_id == ^user.id)
      |> order_by(asc: :id)
      |> Repo.all()
      |> Enum.group_by(& &1.post_id, &%{previous_body: &1.body, edited_at: &1.inserted_at})

    Post
    |> where([p], p.user_id == ^user.id)
    |> join(:inner, [p], t in assoc(p, :thread))
    |> join(:left, [p, t], r in subquery(readable_thread_ids(user)), on: r.id == t.id)
    |> order_by([p], asc: p.id)
    |> select([p, t, r], %{
      id: p.id,
      thread_id: p.thread_id,
      thread_title: fragment("CASE WHEN ? IS NULL THEN NULL ELSE ? END", r.id, t.title),
      body: p.body,
      inserted_at: p.inserted_at,
      edited_at: p.edited_at,
      deleted_at: p.deleted_at
    })
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :revisions, Map.get(revisions, &1.id, [])))
  end

  # Threads whose first post is the user's.
  defp threads_started(user) do
    first_posts =
      from(p in Post,
        distinct: p.thread_id,
        order_by: [asc: p.thread_id, asc: p.inserted_at, asc: p.id],
        select: %{thread_id: p.thread_id, user_id: p.user_id}
      )

    Thread
    |> join(:inner, [t], f in subquery(first_posts), on: f.thread_id == t.id)
    |> join(:inner, [t], c in Category, on: c.id == t.category_id)
    |> join(:left, [t, f, c], r in subquery(readable_category_ids(user)), on: r.id == c.id)
    |> where([t, f], f.user_id == ^user.id)
    |> order_by([t], asc: t.id)
    |> select([t, f, c, r], %{
      id: t.id,
      title: t.title,
      category: fragment("CASE WHEN ? IS NULL THEN NULL ELSE ? END", r.id, c.title),
      inserted_at: t.inserted_at
    })
    |> Repo.all()
  end

  defp likes(user) do
    PostLike
    |> where([l], l.user_id == ^user.id)
    |> join(:inner, [l], p in assoc(l, :post))
    |> order_by([l], asc: l.id)
    |> select([l, p], %{post_id: l.post_id, thread_id: p.thread_id, liked_at: l.inserted_at})
    |> Repo.all()
  end

  defp notifications(user) do
    Notification
    |> where([n], n.user_id == ^user.id)
    |> where(
      [n],
      not is_nil(n.conversation_id) or
        (is_nil(n.thread_id) and n.kind in ^Notification.threadless_kinds()) or
        n.thread_id in subquery(from(r in subquery(readable_thread_ids(user)), select: r.id))
    )
    |> order_by(asc: :id)
    |> select(
      [n],
      map(n, [
        :kind,
        :subject,
        :url,
        :thread_id,
        :post_id,
        :conversation_id,
        :read_at,
        :emailed_at,
        :inserted_at
      ])
    )
    |> Repo.all()
  end

  # Conversations the user is in or wrote in, with everyone's usernames but
  # only the user's own messages. Conversations the user left (or was in
  # only as an author) show just their own messages: their current title and
  # participants are no longer the user's to see.
  defp conversations(user) do
    active =
      Repo.all(
        from(p in ConversationParticipant,
          where: p.user_id == ^user.id and is_nil(p.left_at),
          select: p.conversation_id
        )
      )

    messages =
      Message
      |> where([m], m.user_id == ^user.id)
      |> order_by(asc: :id)
      |> select([m], %{
        id: m.id,
        conversation_id: m.conversation_id,
        body: m.body,
        sent_at: m.inserted_at
      })
      |> Repo.all()
      |> Enum.group_by(& &1.conversation_id, &Map.delete(&1, :conversation_id))

    current =
      Conversation
      |> where([c], c.id in ^active)
      |> preload([:user, participants: :user])
      |> Repo.all()
      |> Enum.map(fn conversation ->
        %{
          id: conversation.id,
          title: conversation.title,
          started_by: conversation.user && conversation.user.username,
          participants:
            for(p <- conversation.participants, is_nil(p.left_at), do: p.user.username),
          your_messages: Map.get(messages, conversation.id, [])
        }
      end)

    left =
      for {id, your_messages} <- messages,
          id not in active,
          do: %{id: id, left: true, your_messages: your_messages}

    Enum.sort_by(current ++ left, & &1.id)
  end

  defp levels(user) do
    %{
      threads:
        Repo.all(
          from(w in "forums_threads_watches",
            join: t in Thread,
            on: t.id == w.assoc_id,
            join: r in subquery(readable_thread_ids(user)),
            on: r.id == t.id,
            where: w.user_id == ^user.id,
            order_by: w.assoc_id,
            select: %{thread_id: t.id, thread_title: t.title, level: w.level}
          )
        ),
      categories:
        CategoryWatch
        |> where([w], w.user_id == ^user.id)
        |> join(:inner, [w], c in Category, on: c.id == w.assoc_id)
        |> join(:inner, [w, c], r in subquery(readable_category_ids(user)), on: r.id == c.id)
        |> order_by([w, c], asc: c.title)
        |> select([w, c], %{category: c.title, level: w.level})
        |> Repo.all(),
      tags:
        TagWatch
        |> where([w], w.user_id == ^user.id)
        |> join(:inner, [w], t in Tag, on: t.id == w.assoc_id)
        |> order_by([w, t], asc: t.name)
        |> select([w, t], %{tag: t.name, level: w.level})
        |> Repo.all()
    }
  end

  defp readable_thread_ids(user) do
    query = from(t in Thread, as: :thread, select: %{id: t.id})
    Policy.readable_threads(query, user)
  end

  defp readable_category_ids(user) do
    Category |> select([c], %{id: c.id}) |> Policy.readable_categories(user)
  end

  defp read_positions(user) do
    ThreadRead
    |> where([r], r.user_id == ^user.id)
    |> order_by(asc: :thread_id)
    |> select([r], %{thread_id: r.thread_id, last_read_post_id: r.last_read_post_id})
    |> Repo.all()
  end
end
