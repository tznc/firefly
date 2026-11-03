defmodule Firefly.Import do
  @moduledoc """
  The Import context: bringing another forum's or chat platform's content
  into Firefly. The importers themselves (reading Discourse, phpBB, Slack
  and so on, and the pipeline that runs them) are the `firefly_import`
  app; this context keeps what they leave here:

    * runs (`Firefly.Import.Run`): each run's status, options, counts and
      log, shown on the staff import page
    * the id map: what each of a source's records (`kind`, its id there)
      became here, so a run that's stopped or repeated carries on where it
      was instead of importing anything twice
    * writing the records (`Firefly.Import.Writer`) with their original
      authors and timestamps
    * permalinks (`Firefly.Import.Permalink`): the old site's URLs, which
      the web app redirects to what they became
    * what's due once an import is done (`after_import/2`): directory
      stats, badges, trust levels, search, and optionally embeddings
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [Run, Permalink, Writer]

  import Ecto.Query

  alias Firefly.{AI, Badges, Directory, Repo, TrustLevels}
  alias Firefly.Import.{ExternalId, Permalink, Run}

  # A run keeps the last lines of its log.
  @log_lines 500

  ## Runs

  @doc """
  Starts a run of the `source` importer with `options` (which are kept
  without passwords, tokens or secrets). Returns `{:ok, run}`.
  """
  def start_run(source, options, dry_run? \\ false) do
    Repo.insert(%Run{
      source: to_string(source),
      dry_run: dry_run?,
      options: options |> Map.new() |> Map.new(fn {k, v} -> {to_string(k), redact(k, v)} end)
    })
  end

  defp redact(key, value) do
    cond do
      to_string(key) =~ ~r/password|token|secret|key/i -> "[redacted]"
      is_binary(value) and value =~ ~r{^[a-z][a-z0-9+.-]*://[^/@]*@}i -> redact_userinfo(value)
      is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) -> value
      true -> inspect(value)
    end
  end

  defp redact_userinfo(url), do: URI.to_string(%{URI.parse(url) | userinfo: "[redacted]"})

  @doc "Saves the run's progress: its `counts` and new `log` lines."
  def update_run(%Run{} = run, counts, new_lines) do
    run
    |> Ecto.Changeset.change(counts: counts, log: Enum.take(run.log ++ new_lines, -@log_lines))
    |> Repo.update!()
  end

  @doc "Ends the run: `\"finished\"` or `\"failed\"` (with `error`), with its final counts and log."
  def finish_run(%Run{} = run, status, counts, new_lines, error \\ nil)
      when status in ["finished", "failed"] do
    run
    |> Ecto.Changeset.change(
      status: status,
      error: error,
      counts: counts,
      log: Enum.take(run.log ++ new_lines, -@log_lines),
      finished_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()
  end

  @doc "The latest runs, newest first."
  def list_runs(limit \\ 50),
    do: Repo.all(from(r in Run, order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit))

  @doc "The run with that id, or nil."
  def get_run(id), do: Repo.get(Run, id)

  ## The id map

  @doc "What each of `external_ids` (of a `kind` of record, from `source`) became: `%{external_id => local_id}`."
  def mapped(source, kind, external_ids) do
    ids = Enum.map(external_ids, &to_string/1)

    Map.new(
      Repo.all(
        from(e in ExternalId,
          where: e.source == ^source and e.kind == ^to_string(kind) and e.external_id in ^ids,
          select: {e.external_id, e.local_id}
        )
      )
    )
  end

  @doc "What the record became here, or nil."
  def local_id(_source, _kind, nil), do: nil

  def local_id(source, kind, external_id),
    do: source |> mapped(kind, [external_id]) |> Map.get(to_string(external_id))

  @doc "Records what the source's record became here."
  def put_id(source, kind, external_id, local_id, run_id \\ nil) do
    Repo.insert!(
      %ExternalId{
        source: source,
        kind: to_string(kind),
        external_id: to_string(external_id),
        local_id: local_id,
        run_id: run_id
      },
      on_conflict: {:replace, [:local_id, :run_id]},
      conflict_target: [:source, :kind, :external_id]
    )

    :ok
  end

  @doc "How many records of each kind were imported from `source`: `%{kind => count}`."
  def imported_counts(source) do
    Map.new(
      Repo.all(
        from(e in ExternalId,
          where: e.source == ^source,
          group_by: e.kind,
          select: {e.kind, count(e.id)}
        )
      )
    )
  end

  ## Permalinks

  @doc """
  Adds a permalink from the old site's `url` (a path, maybe with a query;
  see `normalize_url/1`) to `target`: `{:thread_id, id}`, `{:post_id, id}`,
  `{:category_id, id}`, `{:user_id, id}`, `{:tag_id, id}` or
  `{:external_url, url}`. A URL that's already a permalink keeps its target.
  """
  def put_permalink(source, url, {field, value}) do
    if field in Permalink.targets() and value not in [nil, ""] do
      at = NaiveDateTime.utc_now()

      Repo.insert(
        struct(Permalink, [
          {:url, normalize_url(url)},
          {:source, source},
          {field, value},
          {:inserted_at, at},
          {:updated_at, at}
        ]),
        on_conflict: :nothing,
        conflict_target: :url
      )
    else
      {:error, :no_target}
    end
  end

  @doc """
  A URL as permalinks keep it: without the scheme and host, the leading and
  trailing slashes and the fragment, e.g. `"t/welcome/12"` or
  `"viewtopic.php?t=12"`.
  """
  def normalize_url(url) do
    %URI{path: path, query: query} = URI.parse(String.trim(url))
    path = (path || "") |> URI.decode() |> String.trim("/")
    if query in [nil, ""], do: path, else: path <> "?" <> query
  end

  @doc """
  The permalink for a request's `path` and `query` (raw query string), with
  its target loaded (a post with its thread), or nil. Tries the path and
  query as given, the path with each single query parameter (so
  `viewtopic.php?f=2&t=12` finds `viewtopic.php?t=12`), the path alone,
  then the path less its last segments (so `t/welcome/12/3`, a post
  number, finds `t/welcome/12`).
  """
  def find_permalink(path, query \\ nil) do
    path = path |> URI.decode() |> String.trim("/")

    case candidates(path, query) do
      [] ->
        nil

      urls ->
        Permalink
        |> where([p], p.url in ^urls)
        |> preload([:thread, :category, :user, :tag, post: :thread])
        |> Repo.all()
        |> Enum.min_by(&Enum.find_index(urls, fn url -> url == &1.url end), fn -> nil end)
    end
  end

  defp candidates("", query) when query in [nil, ""], do: []

  defp candidates(path, query) do
    params =
      if query in [nil, ""],
        do: [],
        else:
          query
          |> URI.query_decoder()
          |> Enum.map(fn {k, v} -> "#{path}?#{URI.encode_query([{k, v}])}" end)

    full = if query in [nil, ""], do: [], else: ["#{path}?#{query}"]
    segments = String.split(path, "/", trim: true)

    prefixes =
      for n <- (length(segments) - 1)..1//-1,
          n > 0,
          do: segments |> Enum.take(n) |> Enum.join("/")

    Enum.uniq(full ++ params ++ [path] ++ prefixes)
  end

  ## After an import

  @doc """
  What's due once an import is done, so the imported content shows as if
  it had been posted here: refreshes the directory's stats, grants the
  badges earned, reviews trust levels and, with `embeddings: true` (and
  embeddings set up), embeds the posts for semantic search. Search needs
  nothing: posts are indexed as they're written. Returns a line about each
  step.
  """
  def after_import(opts \\ []) do
    Directory.refresh()
    Badges.grant_earned(nil)
    TrustLevels.review()

    embedded =
      if opts[:embeddings], do: ["Embedded #{embed_all(0)} posts for semantic search."], else: []

    ["Refreshed the directory's stats.", "Granted badges.", "Reviewed trust levels." | embedded]
  end

  defp embed_all(total) do
    case AI.Embeddings.run_due() do
      0 -> total
      count -> embed_all(total + count)
    end
  end
end
