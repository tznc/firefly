defmodule FireflyImport.ChatExport do
  @moduledoc """
  Chat platforms' exports (Slack, Discord), read into channels and messages,
  imported either as chat (`:chat`, the default: chat channels, messages,
  threads and reactions) or as a forum (`:forum`: a category per channel,
  under one per Discord category; a topic per thread, titled by its first
  message or its name, and one per channel and day for the messages
  outside threads; reactions as likes).

  The export (`t:t/0`) is:

    * `users`: user records (see `FireflyImport.Source`)
    * `channels`: `%{id, name, description, user_id, member_ids, created_at, category}`
      (`category`: the name of the group it's in, or nil)
    * `messages`: `%{id, channel_id, user_id, user_names, body, created_at,
      edited_at, thread_id, files, reactions}`, oldest first, where
      `thread_id` is the thread's first message (or the thread's id when
      that isn't exported), `files` are files (see `FireflyImport.Source`)
      with an `id` and `reactions` are `%{emoji, user_ids}`
    * `thread_titles`: `%{thread_id => title}`, for threads that have one
    * `conversations` and `direct_messages`: private conversations and their
      messages (records as for `:conversations` and `:messages`, with `files`)
  """

  @type t :: %{
          users: [map()],
          channels: [map()],
          messages: [map()],
          thread_titles: %{optional(String.t()) => String.t()},
          conversations: [map()],
          direct_messages: [map()]
        }

  @doc "The export's records of a kind, imported `as` chat or a forum."
  def stream(export, _as, :users), do: export.users

  def stream(export, _as, :uploads) do
    for message <- export.messages ++ export.direct_messages,
        file <- message[:files] || [],
        do: Map.merge(file, %{user_id: message.user_id, user_names: message[:user_names]})
  end

  def stream(export, _as, :conversations), do: export.conversations

  def stream(export, _as, :messages) do
    Enum.map(export.direct_messages, &Map.put(&1, :uploads, uploads(&1)))
  end

  def stream(export, :chat, :chat_channels) do
    Enum.map(
      export.channels,
      &Map.take(&1, [:id, :name, :description, :user_id, :member_ids, :created_at])
    )
  end

  def stream(export, :chat, :chat_messages) do
    ids = MapSet.new(export.messages, & &1.id)

    Enum.map(export.messages, fn message ->
      # A reply whose thread's first message wasn't exported is a message of its own.
      thread_id =
        if message.thread_id != message.id and message.thread_id in ids, do: message.thread_id

      message
      |> Map.take([:id, :channel_id, :user_id, :user_names, :body, :created_at, :edited_at])
      |> Map.merge(%{thread_id: thread_id, uploads: uploads(message)})
    end)
  end

  def stream(export, :chat, :reactions) do
    for message <- export.messages,
        %{emoji: emoji, user_ids: user_ids} <- message[:reactions] || [],
        user_id <- user_ids,
        do: %{
          message_id: message.id,
          user_id: user_id,
          emoji: emoji,
          created_at: message.created_at
        }
  end

  def stream(export, :forum, :categories) do
    groups =
      for name <-
            export.channels |> Enum.map(& &1[:category]) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
          do: %{id: "category:" <> name, title: name}

    channels =
      export.channels
      |> Enum.with_index()
      |> Enum.map(fn {channel, position} ->
        %{
          id: channel.id,
          title: channel.name,
          description: channel[:description],
          position: position,
          parent_id: channel[:category] && "category:" <> channel.category,
          created_at: channel[:created_at]
        }
      end)

    groups ++ channels
  end

  def stream(export, :forum, :topics) do
    export
    |> posts()
    |> Enum.uniq_by(& &1.topic_id)
    |> Enum.map(fn post ->
      %{
        id: post.topic_id,
        category_id: post.channel_id,
        title: post.title,
        created_at: post.created_at
      }
    end)
  end

  def stream(export, :forum, :posts) do
    export
    |> posts()
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :topic_id,
        :user_id,
        :user_names,
        :body,
        :uploads,
        :created_at,
        :edited_at
      ])
    )
  end

  def stream(export, :forum, :likes) do
    for message <- export.messages,
        user_id <-
          message[:reactions] |> List.wrap() |> Enum.flat_map(& &1.user_ids) |> Enum.uniq(),
        do: %{post_id: message.id, user_id: user_id, created_at: message.created_at}
  end

  def stream(_export, _as, _kind), do: []

  # Each message as a post, in the topic of its thread (or of its channel's
  # day), with the topic's title.
  defp posts(export) do
    channels = Map.new(export.channels, &{&1.id, &1})
    threads = for %{thread_id: id} <- export.messages, id != nil, into: MapSet.new(), do: id

    Enum.map(export.messages, fn message ->
      thread = message.thread_id || if(message.id in threads, do: message.id)

      {topic_id, title} =
        if thread do
          {"thread:" <> thread, export.thread_titles[thread] || title(message.body)}
        else
          date = message.created_at |> DateTime.to_date() |> Date.to_iso8601()
          {"day:#{message.channel_id}:#{date}", "#{channels[message.channel_id].name} on #{date}"}
        end

      Map.merge(message, %{topic_id: topic_id, title: title, uploads: uploads(message)})
    end)
  end

  # A title from a message: its first line, without Markdown, shortened.
  defp title(body) do
    line =
      body
      |> String.split("\n", trim: true)
      |> List.first("")
      |> String.replace(~r/[*_~`#>\[\]]|\(https?:[^)]*\)/, "")
      |> String.trim()

    cond do
      line == "" -> "Untitled"
      String.length(line) > 80 -> String.slice(line, 0, 77) <> "..."
      true -> line
    end
  end

  defp uploads(message), do: for(file <- message[:files] || [], do: {nil, file.id})
end
