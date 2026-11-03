defmodule FireflyImport.Source do
  @moduledoc """
  An importer's source: a forum's database, an export or an API, read as
  streams of records of each kind, which `FireflyImport.Pipeline` writes
  in this order (a source streams `[]` for a kind it doesn't have):

  | Kind | Fields (`id` is the record's id in the source; `*_id` fields are source ids) |
  | --- | --- |
  | `:users` | `id`, `username`, `name`, `email`, `created_at`, `last_seen_at`, `bio`, `website`, `location`, `trust_level`, `confirmed`, `suspended_until`, `suspend_reason`, `silenced_until`, `identities` (`[%{provider:, uid:, info:}]`), `avatar` (a file, see below) |
  | `:groups` | `id`, `name`, `description` |
  | `:group_members` | `group_id`, `user_id`, `owner` |
  | `:categories` | `id`, `title`, `description`, `color`, `position`, `parent_id` (parents first), `allow_accepted_answers`, `group_ids` (restricted to), `created_at` |
  | `:tags` | `id`, `name`, `group` (a tag group's name) |
  | `:uploads` | `id`, `user_id`, `filename`, and the file: `path`, `data` or `url` |
  | `:topics` | `id`, `category_id`, `title`, `tags` (names), `views`, `pinned_at`, `closed_at`, `archived_at`, `created_at`, `updated_at` |
  | `:posts` | `id`, `topic_id`, `user_id`, `body` (Markdown), `uploads`, `created_at`, `updated_at`, `edited_at`, `deleted_at`, `wiki` (a topic's first post first) |
  | `:likes` | `post_id`, `user_id`, `created_at` |
  | `:bookmarks` | `post_id`, `user_id`, `note`, `created_at` |
  | `:polls` | `id`, `post_id`, `kind`, `min_choices`, `max_choices`, `results`, `public`, `close_at`, `closed_at`, `options` (`[{id, text}]`), `votes` (`[{user_id, option_id, rank}]`) |
  | `:solved` | `topic_id`, `post_id` |
  | `:conversations` | `id`, `title`, `user_id`, `participant_ids`, `group_id`, `created_at` |
  | `:messages` | `id`, `conversation_id`, `user_id`, `body`, `uploads`, `created_at` |
  | `:chat_channels` | `id`, `name`, `description`, `user_id`, `member_ids`, `created_at` |
  | `:chat_messages` | `id`, `channel_id`, `user_id`, `body`, `uploads`, `thread_id` (the message it replies to in a thread), `created_at`, `edited_at`, `deleted_at` |
  | `:reactions` | `message_id`, `user_id`, `emoji`, `created_at` |
  | `:permalinks` | `url` (the old path, e.g. `t/welcome/12`) and one of `topic_id`, `post_id`, `category_id`, `user_id`, `tag` (a name) or `external_url` |

  Timestamps are `DateTime`s or `NaiveDateTime`s in UTC. A `user_id` the
  source doesn't know (nil, or a user it didn't stream) becomes a
  placeholder account; one named in `user_names` (`%{id => username}`, on
  any record) gets that username.

  `uploads` on a post or message: `[{ref, upload_id}]`, the uploads it
  shows. Where `ref` (a string) is in the body, it's replaced with the
  upload's URL; with a nil `ref`, the upload is added at the end.

  A file (an upload, an avatar) is `%{filename:, path: ...}`, `%{filename:,
  data: ...}` or `%{filename:, url: ...}` (downloaded, with any `headers`).
  """

  @typedoc "The source's open state (a connection, a parsed export...)."
  @type state :: term()

  @kinds [
    :users,
    :groups,
    :group_members,
    :categories,
    :tags,
    :uploads,
    :topics,
    :posts,
    :likes,
    :bookmarks,
    :polls,
    :solved,
    :conversations,
    :messages,
    :chat_channels,
    :chat_messages,
    :reactions,
    :permalinks
  ]

  @doc "Every kind of record, in the order they're imported."
  def kinds, do: @kinds

  @doc "The source's name (`discourse`), which its imported ids are kept under."
  @callback name() :: String.t()

  @doc "Its command-line options, as `OptionParser`'s `strict:` switches."
  @callback switches() :: keyword()

  @doc "A line about each option, for `mix help firefly.import`."
  @callback usage() :: String.t()

  @doc "Opens the source (connects, unpacks): `{:ok, state}` or `{:error, message}`."
  @callback open(opts :: keyword()) :: {:ok, state()} | {:error, String.t()}

  @doc "The records of a kind, as a stream (or a list)."
  @callback stream(state(), kind :: atom()) :: Enumerable.t()

  @doc "Closes the source."
  @callback close(state()) :: :ok
end
