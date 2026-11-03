defmodule Firefly.AI.Translations do
  @moduledoc """
  The `translate` feature: a post or chat message in the reader's
  language (their browser's, see `language/1`), for a member who may read
  it. Translations are cached per post or message and language, and made
  again after the text is edited. A cached one doesn't count against
  quotas.
  """

  import Ecto.Query

  alias Firefly.{AI, Chat, Discussion, Repo}
  alias Firefly.Accounts.User
  alias Firefly.AI.{Prompts, Translation}
  alias Firefly.Chat.Message
  alias Firefly.Discussion.Post

  @names %{
    "ar" => "Arabic",
    "bn" => "Bengali",
    "cs" => "Czech",
    "da" => "Danish",
    "de" => "German",
    "el" => "Greek",
    "en" => "English",
    "es" => "Spanish",
    "fa" => "Persian",
    "fi" => "Finnish",
    "fr" => "French",
    "he" => "Hebrew",
    "hi" => "Hindi",
    "hu" => "Hungarian",
    "id" => "Indonesian",
    "it" => "Italian",
    "ja" => "Japanese",
    "ko" => "Korean",
    "ms" => "Malay",
    "nl" => "Dutch",
    "no" => "Norwegian",
    "pl" => "Polish",
    "pt" => "Portuguese",
    "pt-br" => "Brazilian Portuguese",
    "ro" => "Romanian",
    "ru" => "Russian",
    "sv" => "Swedish",
    "th" => "Thai",
    "tr" => "Turkish",
    "uk" => "Ukrainian",
    "vi" => "Vietnamese",
    "zh" => "Chinese",
    "zh-cn" => "Simplified Chinese",
    "zh-tw" => "Traditional Chinese"
  }

  @doc """
  A language tag from the browser (`navigator.language`, e.g. `fr-FR`),
  normalized to lowercase; English for anything that isn't one.
  """
  def language(tag) when is_binary(tag) do
    tag = String.downcase(String.trim(tag))
    if tag =~ ~r/^[a-z]{2,3}(-[a-z0-9]{2,8})?$/, do: tag, else: "en"
  end

  def language(_tag), do: "en"

  @doc "The language's name for the prompt (`fr-fr` is French)."
  def language_name(tag) do
    @names[tag] || @names[hd(String.split(tag, "-"))] || "the language with the tag #{tag}"
  end

  @doc """
  `post` in `language` for `user`: `{:ok, %{text:, cached:}}` or `{:error,
  reason}`. `opts` may have `:stream`.
  """
  def post(%Post{} = post, %User{} = user, language, opts \\ []) do
    post = Repo.preload(post, :thread)

    readable? =
      not Post.deleted?(post) and Post.readable_by?(post, user) and
        Bodyguard.permit?(Discussion, :view_thread, user, post.thread)

    translate(:post_id, post.id, post.body, user, readable?, language, opts)
  end

  @doc "A chat `message` in `language` for `user`, as `post/4`."
  def message(%Message{} = message, %User{} = user, language, opts \\ []) do
    readable? = not Message.deleted?(message) and Chat.message_readable?(message.id, user)
    translate(:chat_message_id, message.id, message.body, user, readable?, language, opts)
  end

  defp translate(field, id, body, user, readable?, language, opts) do
    language = language(language)
    hash = :crypto.hash(:sha256, body)

    cond do
      not AI.available?(user, "translate") ->
        {:error, :disabled}

      not readable? ->
        {:error, :unauthorized}

      cached = cached(field, id, language, hash) ->
        {:ok, %{text: cached.content, cached: true}}

      true ->
        with {:ok, %{text: text}} <-
               AI.chat(user, "translate", [%{role: :user, content: body}],
                 system: Prompts.render("translate", %{"language" => language_name(language)}),
                 stream: opts[:stream]
               ) do
          store(field, id, language, hash, text)
          {:ok, %{text: text, cached: false}}
        end
    end
  end

  defp cached(field, id, language, hash) do
    Repo.one(
      from(t in Translation,
        where: field(t, ^field) == ^id and t.language == ^language and t.source_hash == ^hash
      )
    )
  end

  defp store(field, id, language, hash, text) do
    Repo.transact(fn ->
      Repo.delete_all(
        from(t in Translation, where: field(t, ^field) == ^id and t.language == ^language)
      )

      {:ok,
       Repo.insert!(
         struct(Translation, [{field, id}, language: language, source_hash: hash, content: text])
       )}
    end)
  end
end
