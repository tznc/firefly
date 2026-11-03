defmodule FireflyImport.Sources.Slack do
  @moduledoc """
  Imports a Slack workspace from its export (the ZIP file from Workspace
  settings, Import/Export Data). Options:

    * `--path export.zip` (required; an unzipped export's directory works too)
    * `--as chat` (default: channels become chat channels) or `--as forum`
      (channels become categories, threads topics; see `FireflyImport.ChatExport`)
    * `--token xoxb-...`: a Slack token that can read files, to download the
      files messages share (exports only link them); without it they're
      left out

  What it imports: members (matched to existing accounts by email; bots
  left out), public and private channels with their members, messages
  (Slack's formatting, mentions and links as Markdown; join and leave
  notices left out) with their threads, files and reactions, and direct
  and group messages as private conversations.
  """

  @behaviour FireflyImport.Source

  alias FireflyImport.{ChatExport, Markdown}

  # Message subtypes that are just notices.
  @notices ~w(channel_join channel_leave channel_topic channel_purpose channel_name channel_archive
              channel_unarchive group_join group_leave group_topic group_purpose group_name pinned_item
              unpinned_item bot_add bot_remove)

  @impl true
  def name, do: "slack"

  @impl true
  def switches, do: [path: :string, as: :string, token: :string]

  @impl true
  def usage do
    """
      --path FILE    the export (.zip, or its unzipped directory)
      --as chat      channels as chat channels (default), or --as forum: categories and topics
      --token TOKEN  a Slack token that can read files, to download them
    """
  end

  @impl true
  def open(opts) do
    with {:ok, as} <- as(opts[:as]),
         {:ok, dir, cleanup} <- unpack(opts[:path]) do
      try do
        {:ok, %{as: as, export: read(dir, opts[:token]), cleanup: cleanup}}
      rescue
        error ->
          cleanup.()
          {:error, "can't read the export: #{Exception.message(error)}"}
      end
    end
  end

  @impl true
  def close(%{cleanup: cleanup}) do
    cleanup.()
    :ok
  end

  @impl true
  def stream(%{as: as, export: export}, kind), do: ChatExport.stream(export, as, kind)

  @doc false
  def as(nil), do: {:ok, :chat}
  def as("chat"), do: {:ok, :chat}
  def as("forum"), do: {:ok, :forum}
  def as(other), do: {:error, "--as must be chat or forum, not #{inspect(other)}"}

  @doc false
  # The export's directory: unzipped into a temporary one if it's a ZIP.
  def unpack(nil), do: {:error, "--path is required"}

  def unpack(path) do
    cond do
      File.dir?(path) ->
        {:ok, path, fn -> :ok end}

      File.regular?(path) ->
        unzip(path)

      true ->
        {:error, "#{path} doesn't exist"}
    end
  end

  defp unzip(path) do
    dir = Path.join(System.tmp_dir!(), "firefly-import-#{System.unique_integer([:positive])}")

    case :zip.extract(String.to_charlist(path), cwd: String.to_charlist(dir)) do
      {:ok, _files} -> {:ok, dir, fn -> File.rm_rf(dir) end}
      {:error, reason} -> {:error, "can't unzip #{path}: #{inspect(reason)}"}
    end
  end

  ## Reading the export

  defp read(dir, token) do
    users = json(dir, "users.json")
    names = Map.new(users, &{&1["id"], &1["name"]})
    headers = if token, do: [{"authorization", "Bearer " <> token}]
    channels = json(dir, "channels.json") ++ json(dir, "groups.json")

    channel_messages =
      Enum.flat_map(channels, &messages(dir, &1["name"], &1["id"], names, headers))

    dms =
      Enum.map(json(dir, "dms.json"), &Map.put(&1, "name", &1["id"])) ++ json(dir, "mpims.json")

    %{
      users:
        users |> Enum.reject(&(&1["is_bot"] || &1["id"] == "USLACKBOT")) |> Enum.map(&user/1),
      channels: Enum.map(channels, &channel/1),
      messages: Enum.sort_by(channel_messages, & &1.created_at, DateTime),
      thread_titles: %{},
      conversations: Enum.map(dms, &conversation(&1, names)),
      direct_messages:
        dms
        |> Enum.flat_map(&messages(dir, &1["name"], &1["id"], names, headers))
        |> Enum.map(&Map.put(&1, :conversation_id, &1.channel_id))
    }
  end

  defp json(dir, file) do
    path = Path.join(dir, file)
    if File.exists?(path), do: path |> File.read!() |> Jason.decode!(), else: []
  end

  defp user(user) do
    profile = user["profile"] || %{}

    %{
      id: user["id"],
      username: user["name"],
      name: blank(profile["real_name"]) || blank(user["real_name"]),
      email: profile["email"],
      confirmed: profile["email"] != nil,
      identities: [%{provider: "slack", uid: user["id"]}]
    }
  end

  defp channel(channel) do
    %{
      id: channel["id"],
      name: channel["name"],
      description:
        blank(get_in(channel, ["purpose", "value"])) || blank(get_in(channel, ["topic", "value"])),
      user_id: channel["creator"],
      member_ids: channel["members"] || [],
      created_at: channel["created"] && DateTime.from_unix!(channel["created"])
    }
  end

  defp conversation(dm, names) do
    members = dm["members"] || []

    %{
      id: dm["id"],
      title:
        dm |> Map.get("purpose", %{}) |> Map.get("value") |> blank() ||
          Enum.map_join(members, ", ", &names[&1]),
      user_id: dm["user"] || dm["creator"] || List.first(members),
      participant_ids: members,
      created_at: dm["created"] && DateTime.from_unix!(dm["created"])
    }
  end

  # A channel's messages: one JSON file per day in its directory.
  defp messages(dir, folder, channel_id, names, headers) do
    dir
    |> Path.join(folder)
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&(&1 |> File.read!() |> Jason.decode!()))
    |> Enum.filter(&(&1["type"] == "message" and &1["subtype"] not in @notices and &1["ts"]))
    |> Enum.map(&message(&1, channel_id, names, headers))
  end

  defp message(message, channel_id, names, headers) do
    ts = message["ts"]
    user = message["user"] || message["bot_id"]
    thread = message["thread_ts"]

    %{
      id: "#{channel_id}-#{ts}",
      channel_id: channel_id,
      user_id: user,
      user_names: %{user => author_name(message, names[user])},
      body: to_markdown(message["text"] || "", names),
      created_at: time(ts),
      edited_at: edited_at(message["edited"]),
      thread_id: if(thread && thread != ts, do: "#{channel_id}-#{thread}"),
      files: files(message["files"], headers),
      reactions: reactions(message["reactions"])
    }
  end

  # Bots post under a name of their own.
  defp author_name(message, name),
    do: message["username"] || get_in(message, ["user_profile", "name"]) || name

  defp edited_at(%{"ts" => ts}), do: time(ts)
  defp edited_at(_edited), do: nil

  defp reactions(reactions),
    do: for(r <- reactions || [], do: %{emoji: r["name"], user_ids: r["users"] || []})

  defp files(_files, nil), do: []

  defp files(files, headers) do
    for file <- files || [], url = file["url_private_download"] || file["url_private"] do
      %{
        id: file["id"],
        filename: file["name"] || file["title"] || "file",
        url: url,
        headers: headers
      }
    end
  end

  @doc """
  Slack's message formatting (mrkdwn) as Markdown: `*bold*`, `_italic_`,
  `~strike~`, `<@U123>` mentions, `<#C123|channel>` and `<url|text>` links.
  """
  def to_markdown(text, names) do
    text
    |> String.replace(~r/<@([A-Z0-9]+)(?:\|[^>]*)?>/, fn match ->
      [_, id] = Regex.run(~r/<@([A-Z0-9]+)/, match)
      "@" <> (names[id] || id)
    end)
    |> String.replace(~r/<#[A-Z0-9]+\|([^>]*)>/, "#\\1")
    |> String.replace(~r/<!(here|channel|everyone)(?:\|[^>]*)?>/, "@\\1")
    |> String.replace(~r/<((?:https?|mailto):[^|>]+)\|([^>]+)>/, "[\\2](\\1)")
    |> String.replace(~r/<((?:https?|mailto):[^>]+)>/, "\\1")
    |> String.replace(~r/(?<![\w*])\*(\S(?:[^*\n]*\S)?)\*(?![\w*])/, "**\\1**")
    |> String.replace(~r/(?<![\w~])~(\S(?:[^~\n]*\S)?)~(?![\w~])/, "~~\\1~~")
    |> String.replace(~r/(?<!\w)_(\S(?:[^_\n]*\S)?)_(?!\w)/, "*\\1*")
    |> Markdown.decode_entities()
  end

  defp time(ts) do
    {seconds, micro} =
      case String.split(to_string(ts), ".") do
        [s, us] ->
          {String.to_integer(s),
           us |> String.pad_trailing(6, "0") |> String.slice(0, 6) |> String.to_integer()}

        [s] ->
          {String.to_integer(s), 0}
      end

    DateTime.add(DateTime.from_unix!(seconds), micro, :microsecond)
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
