defmodule FireflyImport.Pipeline do
  @moduledoc """
  Runs an importer: opens its source (see `FireflyImport.Source`), reads
  each kind of record in turn and writes them through `Firefly.Import`,
  in batches (`batch_size`, default 500), each in a transaction.

    * Idempotent and resumable: each record's id in the source is mapped
      to what it became, so a record imported before (by a run that
      stopped or finished) is skipped, and a run can be repeated to pick
      up what's new.
    * A record that fails (a bad reference, an invalid file) is counted
      and logged, and the run carries on.
    * `dry_run: true` does everything in one transaction, rolled back at
      the end, and stores no files: it shows what an import would do.
    * Authors the source doesn't know become placeholder accounts.
    * Old URLs become permalinks, under `permalink_prefix` when the old
      site was in a subfolder (e.g. `forum/`).
    * Once done (not in a dry run), runs `Firefly.Import.after_import/2`
      (`embeddings: true` also embeds the posts), unless `skip_after: true`.

  Progress, counts and the log are kept on the run (`Firefly.Import.Run`,
  shown on the staff import page) and passed to `report`, a function
  called with each log line.
  """

  alias Firefly.{Import, Repo}
  alias Firefly.Import.Writer
  alias FireflyImport.Source

  @batch_size 500
  # Failures logged per kind (the rest are only counted).
  @failures_logged 50

  # What each kind's records are kept as in the id map.
  @id_kinds %{
    users: "user",
    groups: "group",
    categories: "category",
    tags: "tag",
    uploads: "upload",
    topics: "thread",
    posts: "post",
    polls: "poll",
    conversations: "conversation",
    messages: "message",
    chat_channels: "chat_channel",
    chat_messages: "chat_message"
  }

  # Kinds whose ids are few enough to cache for the whole run.
  @cached ~w(user group category tag thread conversation chat_channel)

  @doc """
  Runs the importer `module` with `opts` (its own options and the ones
  above). Returns `{:ok, run}` or `{:error, run}` (`Firefly.Import.Run`).
  """
  def run(module, opts) do
    source = opts[:source_name] || module.name()
    dry_run? = opts[:dry_run] == true
    report = opts[:report] || fn _line -> :ok end
    {:ok, run} = Import.start_run(source, Keyword.drop(opts, [:report]), dry_run?)

    state = %{
      module: module,
      source: source,
      run: run,
      opts: opts,
      dry_run?: dry_run?,
      report: report,
      batch_size: opts[:batch_size] || @batch_size,
      counts: %{},
      lines: [],
      cache: %{}
    }

    state = log(state, "Importing from #{source}#{if dry_run?, do: " (dry run)"}.")

    case module.open(opts) do
      {:ok, handle} ->
        try do
          state |> import_all(handle) |> after_import() |> finish("finished")
        rescue
          error ->
            message = Exception.format(:error, error, __STACKTRACE__)
            state |> log("Failed: #{Exception.message(error)}") |> finish("failed", message)
        after
          module.close(handle)
        end

      {:error, message} ->
        state |> log("Couldn't open the source: #{message}") |> finish("failed", message)
    end
  end

  defp import_all(%{dry_run?: false} = state, handle),
    do: Enum.reduce(Source.kinds(), state, &import_kind(&2, handle, &1))

  # Everything in one transaction, rolled back: the counts and log are
  # kept in the state, which the rollback hands back.
  defp import_all(%{dry_run?: true} = state, handle) do
    {:error, state} =
      Repo.transact(
        fn -> {:error, Enum.reduce(Source.kinds(), state, &import_kind(&2, handle, &1))} end,
        timeout: :infinity
      )

    %{state | cache: %{}}
  end

  defp import_kind(state, handle, kind) do
    started = System.monotonic_time(:millisecond)

    state =
      handle
      |> state.module.stream(kind)
      |> Stream.chunk_every(state.batch_size)
      |> Enum.reduce(state, &import_batch(&2, kind, &1))

    case state.counts[to_string(kind)] do
      nil ->
        state

      counts ->
        seconds = Float.round((System.monotonic_time(:millisecond) - started) / 1000, 1)
        log(state, "#{kind}: done in #{seconds}s, #{summary(counts)}.")
    end
  end

  defp import_batch(state, kind, records) do
    imported = imported(state, kind, records)

    {:ok, state} =
      transaction(state, kind, fn ->
        {:ok, Enum.reduce(records, state, &import_record(&2, kind, &1, imported))}
      end)

    counts = state.counts[to_string(kind)]
    state |> log("#{kind}: #{summary(counts)}") |> save_progress()
  end

  # A dry run is all one transaction already. Uploads are stored one by
  # one: storing a file is a transaction of its own (see Firefly.Uploads),
  # and Ecto rolls back all of a transaction when a nested one fails.
  defp transaction(%{dry_run?: true}, _kind, fun), do: fun.()
  defp transaction(_state, :uploads, fun), do: fun.()
  defp transaction(_state, _kind, fun), do: Repo.transact(fun, timeout: :infinity)

  # Which of the records were imported before.
  defp imported(state, kind, records) do
    case @id_kinds[kind] do
      nil -> %{}
      id_kind -> Import.mapped(state.source, id_kind, for(%{id: id} <- records, do: id))
    end
  end

  defp import_record(state, kind, record, imported) do
    if Map.has_key?(record, :id) and Map.has_key?(imported, to_string(record.id)) do
      count(state, kind, "skipped")
    else
      write_record(state, kind, record)
    end
  end

  defp write_record(state, kind, record) do
    record = strip_nul(record)
    result = isolated(Repo.in_transaction?(), fn -> write(state, kind, record) end)

    case result do
      {:ok, {:skip, state}} ->
        count(state, kind, "skipped")

      {:ok, {local_id, state}} ->
        state |> remember(kind, record, local_id) |> count(kind, "imported")

      {:error, reason} ->
        state
        |> count(kind, "failed")
        |> log_failure(kind, record, reason)
    end
  end

  # Postgres can't store a NUL character, and old forums' text can have
  # them. A file's contents (`data`, in uploads and avatars) are bytes, not
  # text: they're kept as they are.
  defp strip_nul(%{data: data} = file) when is_binary(data),
    do: file |> Map.delete(:data) |> strip_nul() |> Map.put(:data, data)

  defp strip_nul(%_{} = struct), do: struct

  defp strip_nul(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {strip_nul(k), strip_nul(v)} end)

  defp strip_nul(list) when is_list(list), do: Enum.map(list, &strip_nul/1)
  defp strip_nul(other), do: Firefly.Text.strip_nul(other)

  defp remember(state, kind, %{id: id}, local_id) when is_integer(local_id) do
    case @id_kinds[kind] do
      nil ->
        state

      id_kind ->
        Import.put_id(state.source, id_kind, id, local_id, state.run.id)
        cache(state, id_kind, id, local_id)
    end
  end

  defp remember(state, _kind, _record, _local_id), do: state

  # In a transaction, each record in a savepoint: one that fails is rolled
  # back alone, leaving the rest of the batch.
  defp isolated(true = _in_transaction?, fun) do
    Repo.query!("SAVEPOINT import_record")

    case isolated(false, fun) do
      {:ok, _} = ok ->
        Repo.query!("RELEASE SAVEPOINT import_record")
        ok

      error ->
        Repo.query!("ROLLBACK TO SAVEPOINT import_record")
        error
    end
  end

  defp isolated(false, fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  end

  ## Writing each kind

  defp write(state, :users, user) do
    with {:ok, local} <- Writer.user(user) do
      avatar = user[:avatar]

      if avatar && is_nil(local.avatar_upload_id) && not state.dry_run?,
        do: put_avatar(state, local, avatar)

      {:ok, {local.id, state}}
    end
  end

  defp write(state, :groups, group) do
    with {:ok, role} <- Writer.group(group), do: {:ok, {role.id, state}}
  end

  defp write(state, :group_members, member) do
    with {:ok, group_id} <- existing(state, "group", member.group_id),
         {:ok, user_id} <- existing(state, "user", member.user_id),
         {:ok, _} <- Writer.group_member(group_id, user_id, member[:owner]) do
      {:ok, {nil, state}}
    end
  end

  defp write(state, :categories, category) do
    parent_id = local(state, "category", category[:parent_id])
    role_ids = Enum.flat_map(category[:group_ids] || [], &List.wrap(local(state, "group", &1)))

    with {:ok, local} <-
           Writer.category(Map.merge(category, %{parent_id: parent_id, role_ids: role_ids})) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :tags, tag) do
    case Writer.tag(tag.name, tag[:group]) do
      {:ok, nil} -> {:ok, {:skip, state}}
      {:ok, local} -> {:ok, {local.id, cache(state, "tag_name", tag.name, local.id)}}
      error -> error
    end
  end

  defp write(%{dry_run?: true} = state, :uploads, upload) do
    with {:ok, _data} <- file_data(upload), do: {:ok, {:skip, state}}
  end

  defp write(state, :uploads, upload) do
    {user_id, state} = user_id(state, upload, upload[:user_id])

    with {:ok, data} <- file_data(upload),
         {:ok, local} <- Writer.upload(user_id, data, upload.filename) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :topics, topic) do
    {category_id, state} = category_id(state, topic[:category_id])
    {tag_ids, state} = tag_ids(state, topic[:tags] || [])

    with {:ok, thread} <-
           Writer.thread(Map.merge(topic, %{category_id: category_id, tag_ids: tag_ids})) do
      {:ok, {thread.id, state}}
    end
  end

  defp write(state, :posts, post) do
    {user_id, state} = user_id(state, post, post[:user_id])
    {body, upload_ids} = with_uploads(state, post.body, post[:uploads])

    with {:ok, thread_id} <- existing(state, "thread", post.topic_id),
         {:ok, local} <-
           Writer.post(
             Map.merge(post, %{
               thread_id: thread_id,
               user_id: user_id,
               body: body,
               upload_ids: upload_ids
             })
           ) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :likes, like) do
    with {:ok, post_id} <- existing(state, "post", like.post_id),
         {:ok, user_id} <- existing(state, "user", like.user_id),
         {:ok, _} <- Writer.like(post_id, user_id, like[:created_at]) do
      {:ok, {nil, state}}
    end
  end

  defp write(state, :bookmarks, bookmark) do
    with {:ok, post_id} <- existing(state, "post", bookmark.post_id),
         {:ok, user_id} <- existing(state, "user", bookmark.user_id),
         {:ok, _} <- Writer.bookmark(post_id, user_id, bookmark[:created_at], bookmark[:note]) do
      {:ok, {nil, state}}
    end
  end

  defp write(state, :polls, poll) do
    votes =
      for {user_id, option_id, rank} <- poll[:votes] || [],
          local = local(state, "user", user_id),
          do: {local, option_id, rank}

    with {:ok, post_id} <- existing(state, "post", poll.post_id),
         {:ok, local} <- Writer.poll(Map.merge(poll, %{post_id: post_id, votes: votes})) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :solved, solved) do
    with {:ok, thread_id} <- existing(state, "thread", solved.topic_id),
         {:ok, post_id} <- existing(state, "post", solved.post_id),
         {:ok, _} <- Writer.solved(thread_id, post_id) do
      {:ok, {nil, state}}
    end
  end

  defp write(state, :conversations, conversation) do
    {user_id, state} = user_id(state, conversation, conversation[:user_id])

    {participant_ids, state} =
      Enum.map_reduce(conversation[:participant_ids] || [], state, fn id, state ->
        user_id(state, conversation, id)
      end)

    attrs =
      Map.merge(conversation, %{
        user_id: user_id,
        participant_ids: participant_ids,
        role_id: local(state, "group", conversation[:group_id])
      })

    with {:ok, local} <- Writer.conversation(attrs) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :messages, message) do
    {user_id, state} = user_id(state, message, message[:user_id])
    {body, upload_ids} = with_uploads(state, message.body, message[:uploads])

    with {:ok, conversation_id} <- existing(state, "conversation", message.conversation_id),
         {:ok, local} <-
           Writer.message(
             Map.merge(message, %{
               conversation_id: conversation_id,
               user_id: user_id,
               body: body,
               upload_ids: upload_ids
             })
           ) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :chat_channels, channel) do
    {user_id, state} = user_id(state, channel, channel[:user_id])
    member_ids = Enum.flat_map(channel[:member_ids] || [], &List.wrap(local(state, "user", &1)))

    with {:ok, local} <-
           Writer.chat_channel(
             Map.merge(channel, %{created_by_id: user_id, member_ids: member_ids})
           ) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :chat_messages, message) do
    {user_id, state} = user_id(state, message, message[:user_id])
    {body, upload_ids} = with_uploads(state, message.body, message[:uploads])

    with {:ok, channel_id} <- existing(state, "chat_channel", message.channel_id),
         {:ok, root_id} <- optional(state, "chat_message", message[:thread_id]),
         {:ok, local} <-
           Writer.chat_message(
             Map.merge(message, %{
               channel_id: channel_id,
               user_id: user_id,
               body: body,
               upload_ids: upload_ids,
               thread_root_id: root_id
             })
           ) do
      {:ok, {local.id, state}}
    end
  end

  defp write(state, :reactions, reaction) do
    with {:ok, message_id} <- existing(state, "chat_message", reaction.message_id),
         {:ok, user_id} <- existing(state, "user", reaction.user_id),
         {:ok, _} <- Writer.reaction(message_id, user_id, reaction.emoji, reaction[:created_at]) do
      {:ok, {nil, state}}
    end
  end

  defp write(state, :permalinks, permalink) do
    url = (state.opts[:permalink_prefix] || "") <> String.trim_leading(permalink.url, "/")

    case permalink_target(state, permalink) do
      nil ->
        {:ok, {:skip, state}}

      target ->
        case Import.put_permalink(state.source, url, target) do
          {:ok, %{id: nil}} -> {:ok, {:skip, state}}
          {:ok, _} -> {:ok, {nil, state}}
          error -> error
        end
    end
  end

  defp write(_state, kind, _record), do: {:error, "unknown kind of record: #{inspect(kind)}"}

  defp permalink_target(state, permalink) do
    Enum.find_value(
      [
        topic_id: {:thread_id, "thread"},
        post_id: {:post_id, "post"},
        category_id: {:category_id, "category"},
        user_id: {:user_id, "user"},
        tag: {:tag_id, "tag_name"}
      ],
      fn {field, {target, kind}} ->
        if id = permalink[field], do: (local = local(state, kind, id)) && {target, local}
      end
    ) || (permalink[:external_url] && {:external_url, permalink.external_url})
  end

  ## References

  # The local id of the source's record, from the run's cache or the id map.
  defp local(_state, _kind, nil), do: nil

  defp local(state, "tag_name", name) do
    Map.get(state.cache, {"tag_name", to_string(name)}) ||
      case Writer.tag(name) do
        {:ok, %{id: id}} -> id
        _ -> nil
      end
  end

  defp local(state, kind, id) do
    Map.get(state.cache, {kind, to_string(id)}) || Import.local_id(state.source, kind, id)
  end

  defp existing(state, kind, id) do
    case local(state, kind, id) do
      nil -> {:error, "#{kind} #{inspect(id)} wasn't imported"}
      local -> {:ok, local}
    end
  end

  defp optional(_state, _kind, nil), do: {:ok, nil}
  defp optional(state, kind, id), do: existing(state, kind, id)

  defp cache(state, kind, id, local) when kind in @cached or kind == "tag_name",
    do: %{state | cache: Map.put(state.cache, {kind, to_string(id)}, local)}

  defp cache(state, _kind, _id, _local), do: state

  # The author: the imported user, else a placeholder (named as the record's
  # `user_names` say, if they do), made once; nil (unknown) is "ghost".
  defp user_id(state, record, id) do
    case local(state, "user", id || "ghost") do
      nil ->
        name = if id, do: get_in(record, [:user_names, id]) || "imported-#{id}", else: "ghost"
        {:ok, user} = Writer.placeholder_user(name, record[:created_at])
        Import.put_id(state.source, "user", id || "ghost", user.id, state.run.id)
        {user.id, cache(state, "user", id || "ghost", user.id)}

      local ->
        {local, state}
    end
  end

  # The category, else one named "Imported" for topics without one.
  defp category_id(state, id) do
    case local(state, "category", id || "imported") do
      nil when is_nil(id) ->
        {:ok, category} = Writer.category(%{title: "Imported"})
        Import.put_id(state.source, "category", "imported", category.id, state.run.id)
        {category.id, cache(state, "category", "imported", category.id)}

      nil ->
        category_id(state, nil)

      local ->
        {local, state}
    end
  end

  defp tag_ids(state, names) do
    Enum.reduce(names, {[], state}, fn name, {ids, state} ->
      case local(state, "tag_name", name) do
        nil -> {ids, state}
        id -> {[id | ids], cache(state, "tag_name", name, id)}
      end
    end)
  end

  # The body with each upload reference replaced by the upload's URL (or the
  # upload added at the end), and the uploads' ids.
  defp with_uploads(_state, body, uploads) when uploads in [nil, []], do: {body, []}

  defp with_uploads(state, body, uploads) do
    Enum.reduce(uploads, {body, []}, fn {ref, id}, {body, ids} ->
      case local(state, "upload", id) do
        nil -> {body, ids}
        local -> {put_upload(body, ref, Writer.upload_link(local)), [local | ids]}
      end
    end)
  end

  defp put_upload(body, nil, {_url, markdown}),
    do: String.trim_trailing(body) <> "\n\n" <> markdown

  defp put_upload(body, ref, {url, _markdown}), do: String.replace(body, ref, url)

  ## Files

  @doc "A file's contents (see `FireflyImport.Source`): `{:ok, data}` or `{:error, message}`."
  def file_data(%{data: data}) when is_binary(data), do: {:ok, data}

  # Sobelow: a file inside the export the operator is importing.
  # sobelow_skip ["Traversal.FileModule"]
  def file_data(%{path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "can't read #{path}: #{:file.format_error(reason)}"}
    end
  end

  def file_data(%{url: url} = file) when is_binary(url) do
    case Req.get(url,
           headers: file[:headers] || [],
           retry: :transient,
           max_retries: 2,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "downloading #{url} failed: HTTP #{status}"}
      {:error, error} -> {:error, "downloading #{url} failed: #{Exception.message(error)}"}
    end
  end

  def file_data(_file), do: {:error, "no file"}

  defp put_avatar(state, user, avatar) do
    with {:ok, data} <- file_data(avatar),
         {:ok, _user} <- Writer.avatar(user, data, avatar.filename) do
      :ok
    else
      {:error, reason} -> report(state, "Avatar of #{user.username}: #{error_message(reason)}")
    end
  end

  ## Progress

  defp count(state, kind, outcome) do
    counts =
      Map.update(
        state.counts,
        to_string(kind),
        %{outcome => 1},
        &Map.update(&1, outcome, 1, fn n -> n + 1 end)
      )

    %{state | counts: counts}
  end

  defp log_failure(state, kind, record, reason) do
    failed = state.counts[to_string(kind)]["failed"]

    cond do
      failed < @failures_logged ->
        log(
          state,
          "#{kind} #{inspect(record[:id] || Map.take(record, [:post_id, :user_id]))}: #{error_message(reason)}"
        )

      failed == @failures_logged ->
        log(state, "#{kind}: more failures, only counted from here on")

      true ->
        state
    end
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join(", ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error_message(message) when is_binary(message), do: message
  defp error_message(reason), do: inspect(reason)

  defp summary(counts) do
    Enum.map_join(~w(imported skipped failed), ", ", &"#{Map.get(counts, &1, 0)} #{&1}")
  end

  defp log(state, line) do
    report(state, line)
    %{state | lines: state.lines ++ [line]}
  end

  defp report(state, line), do: state.report.(line)

  defp save_progress(%{dry_run?: true} = state), do: state

  defp save_progress(state) do
    run = Import.update_run(state.run, state.counts, state.lines)
    %{state | run: run, lines: []}
  end

  defp after_import(%{dry_run?: true} = state), do: state

  defp after_import(state) do
    if state.opts[:skip_after] do
      state
    else
      state = log(state, "Updating stats, badges and trust levels...")

      [embeddings: state.opts[:embeddings]]
      |> Import.after_import()
      |> Enum.reduce(state, &log(&2, &1))
    end
  end

  defp finish(state, status, error \\ nil) do
    state = log(state, if(status == "finished", do: "Done.", else: "Stopped."))
    run = Import.finish_run(state.run, status, state.counts, state.lines, error)
    if status == "finished", do: {:ok, run}, else: {:error, run}
  end
end
