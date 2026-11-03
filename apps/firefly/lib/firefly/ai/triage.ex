defmodule Firefly.AI.Triage do
  @moduledoc """
  The `triage` feature: each new (or newly approved) post, and any post
  that gets flagged before it was rated, is rated by the model in the
  background for toxicity and spam (0 to 100) and sentiment, as a JSON
  answer (see `Firefly.AI.Classification`). Posting never waits for it.

  What happens next is up to the site settings, on the higher of the two
  scores:

    * at `ai_triage_hide_threshold` or above (0: never), the post is
      flagged and hidden pending review (admins' posts are only flagged);
    * else at `ai_triage_flag_threshold` or above (0: never), it's flagged
      into the review queue with the model's reason;
    * either way, a flagged post's topic gets the `ai_triage_tag` tag, if
      one is set.

  Flags and hides are staff-logged as the system's (`ai.flag`, `ai.hide`).
  Sentiments feed the sentiment report.
  """

  alias Firefly.{AI, Discussion, Repo, SiteSettings}
  alias Firefly.AI.{Classification, Prompts}
  alias Firefly.Discussion.Post
  alias Firefly.Moderation.{Flags, StaffLog}

  @doc """
  Rates `post` and acts on the rating: `{:ok, classification}`, or
  `{:error, reason}` (AI or triage off, the provider failed, or the answer
  wasn't a rating), or `:ok` when it was rated already.
  """
  def classify(%Post{} = post) do
    post = Repo.preload(post, [:thread, :user])

    if Repo.get_by(Classification, post_id: post.id) do
      :ok
    else
      content = "Topic: #{post.thread.title}\n\n#{post.body}"

      with {:ok, %{text: text}} <-
             AI.chat(nil, "triage", [%{role: :user, content: content}],
               system: Prompts.render("triage"),
               json: true,
               max_tokens: 300
             ),
           {:ok, json} <- json(text),
           {:ok, classification} <- insert(post, json) do
        act(post, classification)
        {:ok, classification}
      end
    end
  end

  defp json(text) do
    with :error <- AI.json(text), do: {:error, :invalid_answer}
  end

  # A concurrent rating of the same post (it was flagged as it was posted)
  # wins; this one is dropped.
  defp insert(post, json) do
    changeset = Classification.changeset(%Classification{post_id: post.id}, json)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :post_id) do
      {:ok, %Classification{id: nil}} -> {:error, :already_rated}
      {:ok, classification} -> {:ok, classification}
      {:error, _changeset} -> {:error, :invalid_answer}
    end
  end

  defp act(post, classification) do
    score = max(classification.toxicity, classification.spam)
    hide_at = SiteSettings.get("ai_triage_hide_threshold")
    flag_at = SiteSettings.get("ai_triage_flag_threshold")

    note =
      "AI triage: #{classification.reason || "flagged"} " <>
        "(toxicity #{classification.toxicity}, spam #{classification.spam})"

    cond do
      hide_at > 0 and score >= hide_at ->
        {:ok, _} = Flags.hide_by_system(post, note)
        flagged(post, classification, "ai.hide")

      flag_at > 0 and score >= flag_at ->
        {:ok, _} = Flags.flag_by_system(post, note)
        flagged(post, classification, "ai.flag")

      true ->
        :ok
    end
  end

  defp flagged(post, classification, action) do
    StaffLog.record_system(action, post, %{
      thread: post.thread.title,
      author: post.user && post.user.username,
      toxicity: classification.toxicity,
      spam: classification.spam,
      reason: classification.reason
    })

    tag =
      "ai_triage_tag"
      |> SiteSettings.get()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 30)

    if tag == "", do: :ok, else: Discussion.add_system_tags(post.thread, [tag])
  end
end
