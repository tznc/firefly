defmodule Firefly.AI.Summaries do
  @moduledoc """
  The `summarize` feature: topic summaries and chat catch-ups.

    * A topic with at least `ai_summary_min_posts` posts gets a summary
      button (`topic/3`). The summary covers the topic's published posts
      (not deleted, hidden or awaiting approval: what everyone who may read
      the topic sees), so one cached summary serves every reader; it's
      made again once `ai_summary_stale_posts` new posts arrived. Showing a
      cached summary doesn't count against quotas.
    * In chat, `channel/3` summarizes what a member hasn't read in a
      channel they may view (or, with nothing unread, the latest
      messages). It's theirs alone and never cached.

  Only content the member asking may read is sent: the topic or channel
  must be readable by them. Private messages are never summarized.
  """

  import Ecto.Query

  alias Firefly.{AI, Chat, Discussion, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.AI.{Prompts, Summary}
  alias Firefly.Chat.{Channel, Message}
  alias Firefly.Discussion.{Post, Thread}

  # Roughly 12k tokens of content at most.
  @max_chars 48_000
  @chat_unread 200
  @chat_latest 50

  @doc "Whether a topic with `post_count` posts is long enough for a summary button."
  def summarizable?(post_count), do: post_count >= SiteSettings.get("ai_summary_min_posts")

  @doc """
  The summary of `thread` for `user`: `{:ok, %{text:, cached:}}` or
  `{:error, reason}` (see `Firefly.AI.message/1`). `opts` may have
  `:stream` (see `Firefly.AI.Provider`), used when one is made.
  """
  def topic(%Thread{} = thread, %User{} = user, opts \\ []) do
    with :ok <- authorize(user, Bodyguard.permit?(Discussion, :view_thread, user, thread)) do
      posts = posts(thread)
      count = length(posts)
      stale = SiteSettings.get("ai_summary_stale_posts")

      case Repo.get_by(Summary, thread_id: thread.id) do
        %Summary{post_count: covered} = summary when count - covered < stale ->
          {:ok, %{text: summary.content, cached: true}}

        _missing_or_stale ->
          summarize_topic(thread, posts, user, opts)
      end
    end
  end

  defp authorize(user, readable?) do
    cond do
      not AI.available?(user, "summarize") -> {:error, :disabled}
      not readable? -> {:error, :unauthorized}
      true -> :ok
    end
  end

  defp posts(thread) do
    Post
    |> Post.visible()
    |> where([p], p.thread_id == ^thread.id and is_nil(p.hidden_at))
    |> order_by([p], asc: p.inserted_at, asc: p.id)
    |> preload(:user)
    |> Repo.all()
  end

  defp summarize_topic(thread, posts, user, opts) do
    content =
      posts
      |> Enum.with_index(1)
      |> Enum.map(fn {post, n} -> "Post #{n} by @#{author(post.user)}:\n#{post.body}" end)
      |> fit()

    messages = [%{role: :user, content: "Topic: #{thread.title}\n\n#{content}"}]

    with {:ok, %{text: text}} <-
           AI.chat(user, "summarize", messages,
             system: Prompts.render("summarize_topic"),
             stream: opts[:stream]
           ) do
      Repo.insert!(
        %Summary{thread_id: thread.id, content: text, post_count: length(posts)},
        on_conflict: {:replace, [:content, :post_count, :updated_at]},
        conflict_target: :thread_id
      )

      {:ok, %{text: text, cached: false}}
    end
  end

  @doc """
  A summary, for `user`, of the messages in `channel` they haven't read
  (or the latest, when they've read everything): `{:ok, %{text:, count:}}`
  or `{:error, reason}`. `opts` as `topic/3`.
  """
  def channel(%Channel{} = channel, %User{} = user, opts \\ []) do
    with :ok <- authorize(user, Chat.can?(user, :view_channel, channel)) do
      case channel_messages(channel, user) do
        [] -> {:ok, %{text: "", count: 0}}
        messages -> summarize_channel(channel, messages, user, opts)
      end
    end
  end

  defp summarize_channel(channel, messages, user, opts) do
    content = messages |> Enum.map(&"@#{author(&1.user)}: #{&1.body}") |> fit()
    title = Chat.title(channel, user)

    with {:ok, %{text: text}} <-
           AI.chat(
             user,
             "summarize",
             [%{role: :user, content: "Channel: #{title}\n\n#{content}"}],
             system: Prompts.render("summarize_chat"),
             stream: opts[:stream]
           ),
         do: {:ok, %{text: text, count: length(messages)}}
  end

  defp channel_messages(channel, user) do
    unread =
      case Chat.last_read_message_id(channel, user) do
        nil -> []
        id -> Chat.messages(channel, user, after: id, limit: @chat_unread)
      end

    messages =
      if unread == [], do: Chat.messages(channel, user, limit: @chat_latest), else: unread

    Enum.reject(messages, &Message.deleted?/1)
  end

  defp author(%User{username: username}), do: username
  defp author(_deleted), do: "deleted"

  # Keeps the earliest entries that fit the budget.
  defp fit(entries) do
    entries
    |> Enum.reduce_while({[], 0}, fn entry, {kept, size} ->
      size = size + String.length(entry) + 2
      if size > @max_chars, do: {:halt, {kept, size}}, else: {:cont, {[entry | kept], size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n\n")
  end
end
