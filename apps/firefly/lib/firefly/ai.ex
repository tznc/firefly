defmodule Firefly.AI do
  @moduledoc """
  The AI context: model providers admins configure at `/staff/ai`, which
  provider serves each feature, and the guard every AI request goes
  through.

  ## Providers

  A provider (`Firefly.AI.ProviderConfig`) is an adapter implementing the
  `Firefly.AI.Provider` behaviour (`chat/2`, optionally streaming,
  `embed/2` and `capabilities/0`): `Firefly.AI.Adapters.Anthropic` for the
  Anthropic Messages API and `Firefly.AI.Adapters.OpenAI` for
  OpenAI-compatible APIs (OpenAI, Ollama, vLLM, LM Studio and others, by
  base URL), with its base URL, API key (encrypted at rest), model id and
  limits. `test_provider/1` checks one answers.

  ## Features

  Each feature (`features/0`) is switched on separately, with the provider
  serving it, and can be kept for staff (`update_feature/3`). Nothing is
  sent anywhere unless the `ai_enabled` site setting is on.

  Every request goes through `chat/4` (or `embed/3`), which checks, in
  order: the feature is on (`:disabled`), the site isn't read-only
  (`:read_only`), there's a member asking (`:unauthenticated`) who may use
  it (`:staff_only`), the `:ai` rate limit (`:rate_limited`) and their
  daily quota by trust level (the `ai_daily_quota_tl<n>` settings,
  `:quota`; admins have none). Each answered request is added to the
  usage log (`Firefly.AI.Usage`). A provider's failure is logged and comes
  back as `:provider_failed`.

  Features are responsible for what they send: only content the member
  asking may read (never private messages; direct messages only to their
  members), and their outputs are labelled as AI-generated wherever
  they're shown. Prompts are in `Firefly.AI.Prompts`.
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      ProviderConfig,
      FeatureSetting,
      Provider,
      Prompts,
      Usage,
      Summaries,
      Translations,
      Triage,
      Composer,
      Classification,
      Embeddings,
      SemanticSearch,
      MCP
    ]

  import Ecto.Query

  require Logger

  alias Firefly.{Accounts, Backups, RateLimit, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.AI.{FeatureSetting, ProviderConfig, Usage}
  alias Firefly.Moderation.StaffLog

  @features [
    %{
      key: "summarize",
      label: "Summaries",
      capability: :chat,
      system: false,
      description:
        "A summary button on long topics, and chat summaries of what a member hasn't read."
    },
    %{
      key: "translate",
      label: "Translation",
      capability: :chat,
      system: false,
      description: "Translates a post or chat message into the reader's language."
    },
    %{
      key: "triage",
      label: "Triage",
      capability: :chat,
      system: true,
      description:
        "Rates new and flagged posts for toxicity, spam and sentiment, and flags, hides or tags them."
    },
    %{
      key: "embeddings",
      label: "Semantic search",
      capability: :embed,
      system: true,
      description:
        "Embeds posts so search can also find posts by meaning (a toggle on the search page), and shows related topics under each topic. Needs a provider with embeddings."
    },
    %{
      key: "composer",
      label: "Composer helpers",
      capability: :chat,
      system: false,
      description: "Proofreads a draft and suggests a title and tags while writing."
    }
  ]

  @doc """
  The features, in display order: `key`, `label`, `description`, the
  provider `capability` they need, and whether they're `system` work (no
  member asks; staff-only doesn't apply).
  """
  def features, do: @features

  @doc "The feature with `key`, or nil."
  def feature(key), do: Enum.find(@features, &(&1.key == key))

  @doc "Whether AI is on for the site (the `ai_enabled` setting)."
  def enabled?, do: SiteSettings.get("ai_enabled")

  ## Providers

  @doc "Every provider, by name."
  def list_providers, do: Repo.all(from(p in ProviderConfig, order_by: p.name))

  def get_provider(id), do: Repo.get(ProviderConfig, id)

  @doc "A changeset for the provider form."
  def change_provider(provider \\ %ProviderConfig{}, attrs \\ %{}),
    do: ProviderConfig.changeset(provider, attrs)

  @doc "Adds a provider as `admin` (staff-logged, without its key)."
  def create_provider(attrs, %User{} = admin),
    do: save_provider(%ProviderConfig{}, attrs, admin, "ai_provider.create")

  @doc "Changes `provider` as `admin`; a blank key keeps the stored one."
  def update_provider(%ProviderConfig{} = provider, attrs, %User{} = admin),
    do: save_provider(provider, attrs, admin, "ai_provider.update")

  defp save_provider(provider, attrs, admin, action) do
    changeset = ProviderConfig.changeset(provider, attrs)

    Repo.transact(fn ->
      with {:ok, saved} <- Repo.insert_or_update(changeset) do
        StaffLog.record(admin, action, {"ai_provider", saved.id}, log_details(changeset, saved))
        {:ok, saved}
      end
    end)
  end

  # Never the key itself: only that it changed.
  defp log_details(changeset, saved) do
    details =
      changeset |> StaffLog.changes() |> Map.delete(:api_key) |> Map.put(:name, saved.name)

    if Map.has_key?(changeset.changes, :api_key),
      do: Map.put(details, :api_key, "changed"),
      else: details
  end

  @doc "Deletes `provider` as `admin`; the features it served are turned off."
  def delete_provider(%ProviderConfig{} = provider, %User{} = admin) do
    {:ok, _} =
      Repo.transact(fn ->
        Repo.update_all(from(f in FeatureSetting, where: f.provider_id == ^provider.id),
          set: [enabled: false]
        )

        Repo.delete!(provider)

        StaffLog.record(admin, "ai_provider.delete", {"ai_provider", provider.id}, %{
          name: provider.name
        })

        {:ok, provider}
      end)

    :ok
  end

  @doc """
  Asks `provider` for a two-word answer, to check its URL, key and model:
  `{:ok, %{text: text, ms: duration}}` or `{:error, message}`. Not counted
  as usage.
  """
  def test_provider(%ProviderConfig{} = provider) do
    started = System.monotonic_time(:millisecond)

    messages = [%{role: :user, content: "Reply with the words: connection works"}]

    with {:ok, %{text: text}} <-
           ProviderConfig.module(provider).chat(messages, provider: provider, max_tokens: 20) do
      {:ok, %{text: text, ms: System.monotonic_time(:millisecond) - started}}
    end
  end

  @doc "What `provider`'s adapter can do (see `Firefly.AI.Provider`)."
  def capabilities(%ProviderConfig{} = provider),
    do: ProviderConfig.module(provider).capabilities()

  ## Features

  @doc "Every feature's setting, by key (a blank, off one for features never set up)."
  def feature_settings do
    stored = Map.new(Repo.all(from(f in FeatureSetting, preload: :provider)), &{&1.feature, &1})
    Map.new(@features, &{&1.key, Map.get(stored, &1.key, %FeatureSetting{feature: &1.key})})
  end

  @doc """
  Sets up `feature` as `admin`: `attrs` has `provider_id`, `enabled` and
  `staff_only`. The provider must have the capability the feature needs.
  """
  def update_feature(key, attrs, %User{} = admin) do
    feature = feature(key) || raise ArgumentError, "unknown AI feature #{inspect(key)}"
    setting = Repo.get(FeatureSetting, key) || %FeatureSetting{feature: key}

    changeset =
      setting
      |> FeatureSetting.changeset(attrs)
      |> validate_capability(feature)

    Repo.transact(fn ->
      with {:ok, saved} <- Repo.insert_or_update(changeset) do
        StaffLog.record(admin, "ai_feature.update", {"ai_feature", nil}, %{
          feature: key,
          provider: provider_name(saved.provider_id),
          enabled: saved.enabled,
          staff_only: saved.staff_only
        })

        {:ok, saved}
      end
    end)
  end

  defp validate_capability(changeset, feature) do
    case Ecto.Changeset.get_field(changeset, :provider_id) do
      nil -> changeset
      id -> validate_capability(changeset, feature, get_provider(id))
    end
  end

  defp validate_capability(changeset, _feature, nil),
    do: Ecto.Changeset.add_error(changeset, :provider_id, "doesn't exist")

  defp validate_capability(changeset, feature, provider) do
    if feature.capability in capabilities(provider),
      do: changeset,
      else:
        Ecto.Changeset.add_error(
          changeset,
          :provider_id,
          "this provider can't do #{feature.capability}"
        )
  end

  defp provider_name(nil), do: nil

  defp provider_name(id),
    do: Repo.one(from(p in ProviderConfig, where: p.id == ^id, select: p.name))

  @doc """
  Whether `user` (nil: the system) may use `feature` at all, for showing
  its buttons: AI and the feature are on, and the staff-only restriction
  allows them. Rate limits and quotas are checked when it's used.
  """
  def available?(user, feature) do
    match?({:ok, _provider}, setup(user, feature))
  end

  # The provider serving `feature` for `user`, if they may use it.
  defp setup(user, key) do
    setting = Repo.one(from(f in FeatureSetting, where: f.feature == ^key, preload: :provider))
    feature = feature(key)

    cond do
      not (enabled?() and on?(feature, setting)) ->
        {:error, :disabled}

      Backups.read_only?() ->
        {:error, :read_only}

      feature.system ->
        {:ok, setting.provider}

      is_nil(user) ->
        {:error, :unauthenticated}

      setting.staff_only and not Accounts.admin?(user) ->
        {:error, :staff_only}

      true ->
        {:ok, setting.provider}
    end
  end

  defp on?(nil, _setting), do: false
  defp on?(_feature, %FeatureSetting{enabled: true, provider: %ProviderConfig{}}), do: true
  defp on?(_feature, _setting), do: false

  @doc """
  The provider serving `feature` for `user` once every check passes (see
  the moduledoc), counting against the rate limit: `{:ok, provider}` or
  `{:error, reason}`.
  """
  def check(user, feature) do
    with {:ok, provider} <- setup(user, feature),
         :ok <- rate_limit(user),
         :ok <- within_quota(user) do
      {:ok, provider}
    end
  end

  defp rate_limit(%User{id: id}), do: RateLimit.check(:ai, id)
  defp rate_limit(nil), do: :ok

  defp within_quota(nil), do: :ok

  defp within_quota(user) do
    case quota(user) do
      :unlimited -> :ok
      quota -> if Usage.requests_today(user.id) < quota, do: :ok, else: {:error, :quota}
    end
  end

  @doc "How many AI requests `user` may make a day: a number, or `:unlimited` (admins)."
  def quota(%User{} = user) do
    if Accounts.admin?(user),
      do: :unlimited,
      else: SiteSettings.get("ai_daily_quota_tl#{min(user.trust_level, 4)}")
  end

  @doc "How many AI requests `user` made today."
  def used_today(%User{id: id}), do: Usage.requests_today(id)

  ## Requests

  @doc """
  Sends `messages` to the provider serving `feature`, for `user` (nil: the
  system), after `check/2`. `opts` as `Firefly.AI.Provider` (`:system`,
  `:max_tokens`, `:temperature`, `:json`, `:stream`). `{:ok, %{text:,
  usage:}}` or `{:error, reason}` (see `message/1`).
  """
  def chat(user, feature, messages, opts \\ []) do
    with {:ok, provider} <- check(user, feature) do
      provider
      |> ProviderConfig.module()
      |> apply(:chat, [messages, Keyword.put(opts, :provider, provider)])
      |> answered(feature, user, provider)
    end
  end

  @doc """
  Embeds `texts` with the provider serving `feature` (system work: no
  member, no quota). `{:ok, %{vectors:, usage:}}` or `{:error, reason}`.
  """
  def embed(feature, texts) do
    with {:ok, provider} <- check(nil, feature) do
      module = ProviderConfig.module(provider)

      if :embed in module.capabilities(),
        do: answered(module.embed(texts, provider: provider), feature, nil, provider),
        else: {:error, :disabled}
    end
  end

  defp answered({:ok, %{usage: usage}} = result, feature, user, _provider) do
    :ok = Usage.record(feature, user && user.id, usage)
    result
  end

  defp answered({:error, message}, feature, _user, provider) do
    Logger.warning("AI provider #{provider.name} failed for #{feature}: #{message}")
    {:error, :provider_failed}
  end

  @doc """
  The JSON object in a model's answer (which may wrap it in a code fence
  or a sentence): `{:ok, map}` or `:error`.
  """
  def json(text) when is_binary(text) do
    with [object] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, %{} = decoded} <- Jason.decode(object) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  ## Content events

  @doc """
  A post was published (or approved): triage rates it in the background
  (see `Firefly.AI.Triage`), when triage is on.
  """
  def post_published(%Firefly.Discussion.Post{} = post) do
    :ok = Firefly.AI.Embeddings.embed_later(post)
    triage(post)
  end

  @doc "A post was edited: its embedding is made again in the background."
  def post_edited(%Firefly.Discussion.Post{} = post), do: Firefly.AI.Embeddings.embed_later(post)

  @doc """
  Embeds the posts still missing an up-to-date embedding, a few batches at
  a time (see `Firefly.AI.Embeddings`); run by the scheduler.
  """
  def run_due, do: Firefly.AI.Embeddings.run_due()

  @doc "A post was flagged: triage rates it in the background if it hasn't yet."
  def post_flagged(%Firefly.Discussion.Post{} = post), do: triage(post)

  defp triage(post) do
    if available?(nil, "triage"), do: background(fn -> Firefly.AI.Triage.classify(post) end)
    :ok
  end

  @doc """
  Runs `fun` in the background: AI work never holds up (or fails) what
  triggered it. Tests run it in their own process (`config :firefly,
  Firefly.AI, async: false`).
  """
  def background(fun) do
    if Application.get_env(:firefly, __MODULE__, [])[:async] == false do
      fun.()
    else
      {:ok, _pid} =
        Task.Supervisor.start_child(Firefly.AI.TaskSupervisor, Firefly.Telemetry.bind(fun))
    end

    :ok
  end

  @doc "A message for a reason `chat/4` or `embed/2` gave."
  def message(:disabled), do: "That AI feature is off."
  def message(:read_only), do: "AI features are unavailable while the forum is read-only."
  def message(:unauthenticated), do: "Please log in to use AI features."
  def message(:staff_only), do: "That AI feature is for staff only."
  def message(:rate_limited), do: RateLimit.message()
  def message(:quota), do: "You've used today's AI requests. Try again tomorrow."
  def message(:provider_failed), do: "The AI service didn't answer. Please try again later."
  def message(:unauthorized), do: "You can't use AI on that."
  def message(:empty), do: "Write something first."
end
