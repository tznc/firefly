defmodule Firefly.Moderation.WatchedWords do
  @moduledoc """
  Watched words: words staff list at `/staff/watched-words`, each with an
  action taken when someone writes it in a thread title, post or private
  message (see `Firefly.Moderation.WatchedWord`):

    * `block` - the text isn't saved; the author is told which word
    * `censor` - shown masked (`■■■`) wherever it's rendered
    * `require_approval` - the post waits in the review queue
    * `flag` - the post is published and flagged for staff by the system
    * `replace` - shown as the replacement text
    * `tag` - a new thread gets the word's tags
    * `silence` - the author is silenced (until staff lift it) and the post
      waits for approval
    * `link` - shown as a link to the word's URL

  A word matches case-insensitively and as a whole word; `*` matches any
  run of non-space characters (`spam*` matches "spammer"). A word in regex
  mode is a regular expression used as it is. Blocking applies to
  everyone; approval, flagging and silencing don't apply to admins. The
  author's text is stored as written: censoring, replacing and linking
  happen when it's rendered (`Firefly.Rendering.Markdown`, and `censor/1`
  for plain text such as titles), so changing the list changes old posts
  too, as in Discourse.

  `match/2` is the matching API for any text (chat included). Words are
  compiled into regexes once and kept in `:persistent_term`: loaded at
  start and reloaded on every node when the list changes (see
  `Firefly.SiteSettings.Cache`). Adding and removing words goes to the
  staff log.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [add_error: 4, get_change: 2, put_change: 3]

  alias Firefly.{Accounts, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.Post
  alias Firefly.Moderation.{Flags, Penalties, StaffLog, WatchedWord}

  @cache_key {__MODULE__, :matchers}

  ## Managing the list

  @doc "The words watched for `action`, alphabetically."
  def list(action) do
    WatchedWord
    |> where([w], w.action == ^action)
    |> order_by([w], fragment("lower(?)", w.word))
    |> Repo.all()
  end

  @doc "How many words each action has, by action."
  def counts do
    WatchedWord
    |> group_by([w], w.action)
    |> select([w], {w.action, count(w.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "A changeset for the add form."
  def change_word(attrs \\ %{}), do: WatchedWord.changeset(%WatchedWord{}, attrs)

  @doc "Adds a watched word as `admin`: `{:ok, word}` or `{:error, changeset}`."
  def create(%User{} = admin, attrs) do
    result =
      Repo.transact(fn ->
        with {:ok, word} <-
               %WatchedWord{created_by_id: admin.id}
               |> WatchedWord.changeset(attrs)
               |> Repo.insert() do
          StaffLog.record(admin, "watched_word.create", {"watched_word", word.id}, details(word))
          {:ok, word}
        end
      end)

    with {:ok, _word} <- result, do: changed()
    result
  end

  @doc "Stops watching `word`, as `admin`."
  def delete(%WatchedWord{} = word, %User{} = admin) do
    {:ok, _} =
      Repo.transact(fn ->
        Repo.delete!(word)
        StaffLog.record(admin, "watched_word.delete", {"watched_word", word.id}, details(word))
        {:ok, word}
      end)

    changed()
    :ok
  end

  defp details(word),
    do: %{word: word.word, action: word.action, regex: word.regex, replacement: word.replacement}

  ## Matching

  @doc """
  The distinct words in `text` that match a word watched for `action`, as
  written in `text` (lowercased), in order of appearance.
  """
  def match(text, action) when is_binary(text) do
    matchers()
    |> Map.get(action, [])
    |> Enum.flat_map(fn {_word, regex} -> Regex.scan(regex, text, return: :index) end)
    |> Enum.map(fn [{start, length} | _groups] -> {start, binary_part(text, start, length)} end)
    |> Enum.reject(fn {_start, found} -> found == "" end)
    |> Enum.sort()
    |> Enum.map(&String.downcase(elem(&1, 1)))
    |> Enum.uniq()
  end

  def match(nil, _action), do: []

  @doc """
  Compiles watched words into matchers: by action, a list of `{word,
  regex}`. Words whose regex doesn't compile are left out.
  """
  def compile(words) do
    words
    |> Enum.flat_map(fn word ->
      case Regex.compile(pattern(word), "iu") do
        {:ok, regex} -> [{word.action, {word, regex}}]
        {:error, _} -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # A plain word must stand alone: no letter, digit or underscore next to it.
  defp pattern(%{regex: true, word: word}), do: word

  defp pattern(%{word: word}) do
    body = word |> String.split("*") |> Enum.map_join("\\S*", &Regex.escape/1)
    "(?<![\\p{L}\\p{N}_])" <> body <> "(?![\\p{L}\\p{N}_])"
  end

  @doc "The compiled matchers (see `compile/1`), cached."
  def matchers do
    case :persistent_term.get(@cache_key, nil) do
      nil -> reload()
      matchers -> matchers
    end
  end

  @doc "Loads the words into this node's cache. Returns the matchers."
  def reload do
    matchers = WatchedWord |> Repo.all() |> compile()
    put_cache(matchers)
    matchers
  end

  @doc false
  def put_cache(matchers), do: :persistent_term.put(@cache_key, matchers)

  # This node reloads at once; the others when they hear of it.
  defp changed do
    reload()

    Phoenix.PubSub.broadcast(
      Firefly.PubSub,
      SiteSettings.topic(),
      {:watched_words_changed, node()}
    )
  end

  ## Rendering

  @doc "`text` with censored words masked, for plain text (titles, excerpts)."
  def censor(text, matchers \\ matchers())

  def censor(text, matchers) when is_binary(text) do
    case matchers["censor"] do
      nil -> text
      censored -> mask(text, censored)
    end
  end

  def censor(nil, _matchers), do: nil

  defp mask(text, censored) do
    Enum.reduce(censored, text, fn {_word, regex}, text ->
      Regex.replace(regex, text, &String.duplicate("■", String.length(&1)))
    end)
  end

  @doc """
  What a run of text in a post shows: `replace` words replaced, `censor`
  words masked and `link` words split out as links. A list of `{:text,
  text}` and `{:link, text, url}`. `links?` false (text already in a link)
  leaves the links out. `matchers`: see `matchers/0`.
  """
  def render_text(text, links? \\ true, matchers \\ matchers()) do
    text = replace(text, matchers["replace"] || [])
    links = if links?, do: matchers["link"] || [], else: []

    text
    |> split_links(links)
    |> Enum.map(fn
      {:text, text} -> {:text, mask(text, matchers["censor"] || [])}
      {:link, text, url} -> {:link, mask(text, matchers["censor"] || []), url}
    end)
  end

  defp replace(text, words) do
    Enum.reduce(words, text, fn {word, regex}, text ->
      Regex.replace(regex, text, fn _found -> word.replacement end)
    end)
  end

  defp split_links(text, []), do: [{:text, text}]

  defp split_links(text, [{word, regex} | rest]) do
    regex
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.flat_map(fn part ->
      if Regex.run(regex, part, capture: :first) == [part],
        do: [{:link, part, word.replacement}],
        else: split_links(part, rest)
    end)
  end

  ## Posting

  @doc """
  Checks the `:title` and `:body` a changeset changes (a thread, post,
  edit, conversation or message): a blocked word is an error on its
  field. A post (a changeset with `queued_at`) with a word that needs
  approval or silences its author is queued for review, unless the author
  is an admin. `opts`: `title`, the thread title a first post is written
  under.
  """
  def validate(%Ecto.Changeset{} = changeset, %User{} = user, opts \\ []) do
    texts =
      for field <- [:title, :body],
          text = get_change(changeset, field),
          is_binary(text),
          do: {field, text}

    changeset = Enum.reduce(texts, changeset, &block/2)

    queue(
      changeset,
      user,
      Enum.map_join(texts, "\n", &elem(&1, 1)) <> "\n" <> (opts[:title] || "")
    )
  end

  defp block({field, text}, changeset) do
    case match(text, "block") do
      [] ->
        changeset

      words ->
        add_error(changeset, field, "contains a word that's not allowed: %{words}",
          words: Enum.join(words, ", "),
          validation: :watched_word
        )
    end
  end

  defp queue(%Ecto.Changeset{data: %Post{queued_at: nil}} = changeset, user, text) do
    words = match(text, "require_approval") ++ match(text, "silence")

    if words == [] or Accounts.admin?(user) or get_change(changeset, :queued_at) do
      changeset
    else
      changeset
      |> put_change(:queued_at, DateTime.utc_now(:second))
      |> put_change(:queued_reason, "Watched words: " <> Enum.join(Enum.uniq(words), ", "))
    end
  end

  defp queue(changeset, _user, _text), do: changeset

  @doc """
  After `post` was saved (with `title` for a new thread's first post):
  silences its author for a `silence` word, and flags it for a `flag`
  word (unless it's waiting for approval anyway). Not for admins.
  """
  def posted(%Post{} = post, %User{} = user, title \\ nil) do
    text = Enum.join([title || "", post.body || ""], "\n")

    with [_ | _] = words <- written(text, user),
         false <- Post.queued?(post) do
      Flags.flag_by_system(post, "Watched words: " <> Enum.join(words, ", "))
    end

    :ok
  end

  @doc """
  After `user` wrote and saved `text` (a post, a chat message): silences
  them for a `silence` word, and returns the `flag` words in it, for the
  caller to flag what they wrote. Admins are neither silenced nor
  flagged (`[]`).
  """
  def written(text, %User{} = user) do
    if Accounts.admin?(user) do
      []
    else
      with [_ | _] = words <- match(text, "silence") do
        Penalties.penalize(:silence, user, :system, %{
          "duration" => "forever",
          "reason" => "You wrote a word that isn't allowed here: #{Enum.join(words, ", ")}"
        })
      end

      match(text, "flag")
    end
  end

  @doc "The tags a new thread with `title` and `body` gets from `tag` words."
  def tags(title, body) do
    text = Enum.join([title || "", body || ""], "\n")

    matchers()
    |> Map.get("tag", [])
    |> Enum.filter(fn {_word, regex} -> Regex.match?(regex, text) end)
    |> Enum.flat_map(fn {word, _regex} -> WatchedWord.tag_names(word.replacement) end)
    |> Enum.uniq()
  end
end
