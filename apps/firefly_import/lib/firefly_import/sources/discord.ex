defmodule FireflyImport.Sources.Discord do
  @moduledoc """
  Imports a Discord server from DiscordChatExporter's JSON exports (one
  file per channel or thread: export the server with `--format Json`).
  Options:

    * `--path DIR` (required): the directory of JSON files (or one file)
    * `--as chat` (default: channels become chat channels, threads chat
      threads) or `--as forum` (Discord's categories and channels become
      categories and subcategories, threads and forum posts topics; see
      `FireflyImport.ChatExport`)
    * `--download`: download attachments from Discord's CDN (the links in
      the export expire, so do it soon after exporting); without it,
      attachments exported alongside (`--media`) are read from the files
      the JSON points to, others left out

  What it imports: the members who wrote (no email: accounts linked to
  their Discord account, so logging in with Discord gets theirs back),
  channels, messages (with edits, attachments and reactions; system
  messages left out) and threads.
  """

  @behaviour FireflyImport.Source

  alias FireflyImport.ChatExport
  alias FireflyImport.Sources.Slack

  # Message types that are content (not joins, pins, boosts, nor a thread's
  # copy of the message that started it, which its parent channel has).
  @content ~w(Default Reply)
  @thread_types ~w(GuildPublicThread GuildPrivateThread GuildNewsThread)

  @impl true
  def name, do: "discord"

  @impl true
  def switches, do: [path: :string, as: :string, download: :boolean]

  @impl true
  def usage do
    """
      --path DIR    DiscordChatExporter's JSON files (a directory, or one file)
      --as chat     channels as chat channels (default), or --as forum: categories and topics
      --download    download attachments from Discord's CDN
    """
  end

  @impl true
  def open(opts) do
    with {:ok, as} <- Slack.as(opts[:as]),
         {:ok, files} <- files(opts[:path]) do
      {:ok, %{as: as, export: read(files, opts[:download] == true)}}
    end
  rescue
    error -> {:error, "can't read the export: #{Exception.message(error)}"}
  end

  @impl true
  def close(_state), do: :ok

  @impl true
  def stream(%{as: as, export: export}, kind), do: ChatExport.stream(export, as, kind)

  defp files(nil), do: {:error, "--path is required"}

  defp files(path) do
    cond do
      File.dir?(path) -> {:ok, path |> Path.join("**/*.json") |> Path.wildcard() |> Enum.sort()}
      File.regular?(path) -> {:ok, [path]}
      true -> {:error, "#{path} doesn't exist"}
    end
  end

  # Sobelow: the export files the operator named on the command line.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(files, download?) do
    exports = Enum.map(files, &{Path.dirname(&1), &1 |> File.read!() |> Jason.decode!()})

    {threads, channels} =
      Enum.split_with(exports, fn {_dir, e} -> e["channel"]["type"] in @thread_types end)

    channel_ids = MapSet.new(channels, fn {_dir, e} -> e["channel"]["id"] end)

    # A thread's messages go in its parent channel's, under the message
    # that started it (whose id is the thread's).
    messages =
      Enum.flat_map(channels, fn {dir, e} ->
        messages(e, e["channel"]["id"], nil, dir, download?)
      end) ++
        Enum.flat_map(threads, fn {dir, e} ->
          parent = e["channel"]["categoryId"]
          channel_id = if parent in channel_ids, do: parent, else: e["channel"]["id"]
          messages(e, channel_id, e["channel"]["id"], dir, download?)
        end)

    # Threads whose parent wasn't exported are channels of their own.
    orphans =
      for {_dir, e} = thread <- threads, e["channel"]["categoryId"] not in channel_ids, do: thread

    authors =
      exports
      |> Enum.flat_map(fn {_dir, e} -> Enum.map(e["messages"] || [], & &1["author"]) end)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.reject(& &1["isBot"])

    %{
      users: Enum.map(authors, &user/1),
      channels: Enum.map(channels ++ orphans, fn {_dir, e} -> channel(e) end),
      messages: Enum.sort_by(messages, & &1.created_at, DateTime),
      thread_titles:
        Map.new(threads, fn {_dir, e} -> {e["channel"]["id"], e["channel"]["name"]} end),
      conversations: [],
      direct_messages: []
    }
  end

  defp user(author) do
    %{
      id: author["id"],
      username: author["name"],
      name: author["nickname"] || author["name"],
      identities: [%{provider: "discord", uid: author["id"]}]
    }
  end

  defp channel(%{"channel" => channel} = export) do
    first = List.first(export["messages"] || [])

    %{
      id: channel["id"],
      name: channel["name"],
      description: channel["topic"],
      category: channel["category"],
      member_ids: [],
      created_at: first && time(first["timestamp"])
    }
  end

  defp messages(export, channel_id, thread_id, dir, download?) do
    for message <- export["messages"] || [], message["type"] in @content do
      author = message["author"] || %{}

      %{
        id: message["id"],
        channel_id: channel_id,
        user_id: author["id"],
        user_names: %{author["id"] => author["name"]},
        body: String.trim(message["content"] || ""),
        created_at: time(message["timestamp"]),
        edited_at: message["timestampEdited"] && time(message["timestampEdited"]),
        thread_id: thread_id,
        files: attachments(message["attachments"], dir, download?),
        reactions: reactions(message["reactions"])
      }
    end
  end

  defp attachments(attachments, dir, download?) do
    for attachment <- attachments || [], file = file(attachment, dir, download?) do
      Map.merge(file, %{id: attachment["id"], filename: attachment["fileName"] || "file"})
    end
  end

  defp file(%{"url" => "http" <> _ = url}, _dir, true), do: %{url: url}
  defp file(%{"url" => "http" <> _}, _dir, false), do: nil

  defp file(%{"url" => path}, dir, _download?) when is_binary(path),
    do: %{path: Path.expand(URI.decode(path), dir)}

  defp file(_attachment, _dir, _download?), do: nil

  # Who reacted, when the export has them (newer exports do); emoji by name.
  defp reactions(reactions) do
    for reaction <- reactions || [], users = reaction["users"], users not in [nil, []] do
      %{
        emoji: reaction["emoji"]["code"] || reaction["emoji"]["name"],
        user_ids: Enum.map(users, & &1["id"])
      }
    end
  end

  defp time(iso) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso)
    at
  end
end
