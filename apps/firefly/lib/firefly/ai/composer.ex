defmodule Firefly.AI.Composer do
  @moduledoc """
  The `composer` feature: helpers for what a member is writing (their own
  draft, so nothing they can't read is sent). Staff pick which are offered
  with the `ai_composer_proofread`, `ai_composer_title` and
  `ai_composer_tags` site settings.

    * `proofread/2` - the draft with spelling and grammar fixed
    * `suggest_title/2` - a title for a new topic
    * `suggest_tags/2` - up to five tags, preferring existing ones
  """

  import Ecto.Query

  alias Firefly.{AI, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.AI.Prompts
  alias Firefly.Discussion.Tag

  @helpers %{
    proofread: "ai_composer_proofread",
    title: "ai_composer_title",
    tags: "ai_composer_tags"
  }

  @doc "The helpers `user` is offered: a subset of `[:proofread, :title, :tags]`."
  def helpers(user) do
    if AI.available?(user, "composer"),
      do:
        for(helper <- [:proofread, :title, :tags], SiteSettings.get(@helpers[helper]), do: helper),
      else: []
  end

  @doc "`text` proofread: `{:ok, text}` or `{:error, reason}`."
  def proofread(%User{} = user, text), do: run(user, :proofread, "proofread", text, %{})

  @doc "A title for a topic starting with `text`: `{:ok, title}` or `{:error, reason}`."
  def suggest_title(%User{} = user, text) do
    with {:ok, title} <- run(user, :title, "suggest_title", text, %{}),
         do: {:ok, title |> String.trim() |> String.trim("\"") |> String.slice(0, 100)}
  end

  @doc "Up to five tag names for a topic starting with `text`: `{:ok, names}` or `{:error, reason}`."
  def suggest_tags(%User{} = user, text) do
    known =
      Repo.all(
        from(t in Tag,
          where: is_nil(t.synonym_of_id),
          order_by: t.name,
          limit: 200,
          select: t.name
        )
      )

    with {:ok, answer} <-
           run(user, :tags, "suggest_tags", text, %{"tags" => Enum.join(known, ", ")}, json: true),
         {:ok, %{"tags" => tags}} when is_list(tags) <- AI.json(answer) do
      {:ok,
       tags
       |> Enum.filter(&is_binary/1)
       |> Enum.map(
         &(&1
           |> String.downcase()
           |> String.replace(~r/[^a-z0-9]+/, "-")
           |> String.trim("-"))
       )
       |> Enum.reject(&(&1 == "" or String.length(&1) > 30))
       |> Enum.uniq()
       |> Enum.take(5)}
    else
      {:error, reason} -> {:error, reason}
      _not_tags -> {:error, :provider_failed}
    end
  end

  defp run(user, helper, prompt, text, bindings, opts \\ []) do
    cond do
      helper not in helpers(user) ->
        {:error, :disabled}

      String.trim(text || "") == "" ->
        {:error, :empty}

      true ->
        with {:ok, %{text: answer}} <-
               AI.chat(
                 user,
                 "composer",
                 [%{role: :user, content: text}],
                 [system: Prompts.render(prompt, bindings)] ++ opts
               ),
             do: {:ok, answer}
    end
  end
end
