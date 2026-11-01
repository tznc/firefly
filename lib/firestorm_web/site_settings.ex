defmodule FirestormWeb.SiteSettings do
  @moduledoc """
  Site settings admins edit at runtime (at `/staff/settings`), stored in
  `forums_site_settings` as key/value rows.

  The settings, their types and defaults are defined here; a row exists only
  for a setting an admin changed, so every default is the behavior the site
  had before settings existed (two defaults come from the deployment's
  config: `FIREFLY_TAGS_ADMIN_ONLY` and the `:post` rate limit).

  Reads are served from `:persistent_term`. An update clears the cache on
  this node at once, and on every node through PubSub (see
  `FirestormWeb.SiteSettings.Cache`), so the next read loads the new values
  (clearing starts a new cache generation, so a read racing the update
  can't put old values back).
  The cache is off in tests (`config :firestorm_web, :site_settings_cache`),
  where each test's settings live in its own database transaction.
  """

  import Ecto.Query

  alias FirestormWeb.{RateLimit, Repo, StaffLog}
  alias FirestormWeb.Forums.SiteSetting

  @pubsub FirestormWeb.PubSub
  @topic "site_settings"
  @cache_key {__MODULE__, :values}
  @generation_key {__MODULE__, :generation}

  @doc """
  Every setting, in display order: `key`, `section`, `type` (`:string`,
  `:text`, `:email`, `:boolean` or `:integer`), `label`, `help`, `default`,
  and for integers `min`/`max`.
  """
  def definitions do
    [
      %{
        key: "title",
        section: "Site",
        type: :string,
        label: "Title",
        default: "Firefly",
        help: "The site's name: in the header, page titles and emails."
      },
      %{
        key: "description",
        section: "Site",
        type: :text,
        label: "Description",
        default: "",
        help: "Shown on the home page and to search engines. Blank: none."
      },
      %{
        key: "contact_email",
        section: "Site",
        type: :email,
        label: "Contact email",
        default: "",
        help: "Linked from the sidebar as the way to reach staff. Blank: none."
      },
      %{
        key: "allow_registrations",
        section: "Registration",
        type: :boolean,
        label: "Allow new registrations",
        default: true,
        help: "Off: nobody can create an account, with a password or GitHub."
      },
      %{
        key: "require_email_confirmation",
        section: "Registration",
        type: :boolean,
        label: "Require email confirmation",
        default: true,
        help:
          "Off: members can post without confirming their email. Email notifications still go only to confirmed addresses."
      },
      %{
        key: "new_user_max_links",
        section: "Spam and new users",
        type: :integer,
        label: "Links per post for new users",
        default: 2,
        min: 0,
        max: 100,
        help: "How many links a new account's post may contain."
      },
      %{
        key: "new_user_hours",
        section: "Spam and new users",
        type: :integer,
        label: "New-user period (hours)",
        default: 24,
        min: 0,
        max: 24 * 365,
        help: "Accounts are new until this old (and until they have 3 posts)."
      },
      %{
        key: "max_mentions",
        section: "Spam and new users",
        type: :integer,
        label: "Mentions per post",
        default: 10,
        min: 0,
        max: 100,
        help: "How many users one post may @mention."
      },
      %{
        key: "posts_per_minute",
        section: "Spam and new users",
        type: :integer,
        label: "Posts per minute",
        default: RateLimit.configured_limit(:post),
        min: 1,
        max: 10_000,
        help: "New threads, replies and messages one user may post per minute."
      },
      %{
        key: "tags_admin_only",
        section: "Spam and new users",
        type: :boolean,
        label: "Only admins create tags",
        default: Application.get_env(:firestorm_web, :tags_admin_only, false),
        help: "On: members can only use existing tags."
      },
      %{
        key: "max_tags_per_thread",
        section: "Content",
        type: :integer,
        label: "Tags per thread",
        default: 5,
        min: 0,
        max: 20,
        help: "How many tags a thread may have."
      },
      %{
        key: "edit_grace_minutes",
        section: "Content",
        type: :integer,
        label: "Edit window (minutes)",
        default: 0,
        min: 0,
        max: 525_600,
        help: "How long authors can edit their posts. 0: forever. Admins can always edit."
      },
      %{
        key: "flags_to_hide",
        section: "Content",
        type: :integer,
        label: "Flags to hide a post",
        default: 3,
        min: 1,
        max: 100,
        help: "A post flagged by this many members is hidden until staff review it."
      }
    ]
  end

  @doc "The setting's current value."
  def get(key), do: Map.fetch!(all(), key)

  @doc "Every setting's current value, by key."
  def all, do: elem(cached(), 0)

  @doc """
  Whether an admin has set `key` (a row exists), as opposed to it holding
  its default.
  """
  def customized?(key), do: key in elem(cached(), 1)

  # `{values, customized keys}`. The cache entry is tagged with the
  # generation it was loaded in; invalidating starts a new generation, so an
  # entry a slow reader loaded before a save and put after it is never
  # served.
  defp cached do
    if Application.get_env(:firestorm_web, :site_settings_cache, true) do
      generation = :persistent_term.get(@generation_key, nil)

      case :persistent_term.get(@cache_key, nil) do
        {^generation, values, customized} ->
          {values, customized}

        _missing_or_stale ->
          {values, customized} = load()
          :persistent_term.put(@cache_key, {generation, values, customized})
          {values, customized}
      end
    else
      load()
    end
  end

  defp load do
    stored = Map.new(Repo.all(from(s in SiteSetting, select: {s.key, s.value})))

    values =
      Map.new(definitions(), fn definition ->
        value =
          with raw when is_binary(raw) <- stored[definition.key],
               {:ok, value} <- cast(definition, raw) do
            value
          else
            _unset_or_invalid -> definition.default
          end

        {definition.key, value}
      end)

    {values, MapSet.new(Map.keys(stored))}
  end

  @doc """
  Saves the settings in `params` (key to form value) as `admin`. Each value
  is validated for its type; on any error nothing is saved and the errors
  come back by key. Each changed setting goes to the staff log with its old
  and new values.
  """
  def update(params, admin) do
    current = all()

    {changes, errors} =
      definitions()
      |> Enum.filter(&Map.has_key?(params, &1.key))
      |> Enum.reduce({%{}, %{}}, &collect(&1, params[&1.key], current, &2))

    if errors == %{}, do: save(changes, current, admin), else: {:error, errors}
  end

  # Adds the setting to the changes (if its value changed) or the errors.
  defp collect(%{key: key} = definition, raw, current, {changes, errors}) do
    case cast(definition, raw) do
      {:ok, value} when value == :erlang.map_get(key, current) -> {changes, errors}
      {:ok, value} -> {Map.put(changes, key, value), errors}
      {:error, message} -> {changes, Map.put(errors, key, message)}
    end
  end

  defp save(changes, current, admin) do
    {:ok, _} =
      Repo.transact(fn ->
        for {key, value} <- changes do
          Repo.insert!(%SiteSetting{key: key, value: encode(value)},
            on_conflict: [set: [value: encode(value), updated_at: NaiveDateTime.utc_now()]],
            conflict_target: :key
          )

          StaffLog.record(admin, "setting.update", {"setting", nil}, %{
            key: key,
            value: %{before: current[key], after: value}
          })
        end

        {:ok, changes}
      end)

    if changes != %{}, do: invalidate()
    {:ok, changes}
  end

  defp invalidate do
    clear_cache()
    Phoenix.PubSub.broadcast_from(@pubsub, self(), @topic, :site_settings_changed)
  end

  @doc false
  def topic, do: @topic

  @doc false
  def clear_cache, do: :persistent_term.put(@generation_key, make_ref())

  defp encode(value), do: to_string(value)

  @doc "Casts a form value for the setting's type: `{:ok, value}` or `{:error, message}`."
  def cast(%{type: :boolean}, value) when value in ["true", true], do: {:ok, true}
  def cast(%{type: :boolean}, value) when value in ["false", false], do: {:ok, false}
  def cast(%{type: :boolean}, _value), do: {:error, "must be on or off"}

  def cast(%{type: :integer} = definition, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n < definition.min -> {:error, "must be at least #{definition.min}"}
      {n, ""} when n > definition.max -> {:error, "must be at most #{definition.max}"}
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be a whole number"}
    end
  end

  def cast(%{type: :string}, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "can't be blank"}
      value when byte_size(value) > 100 -> {:error, "must be at most 100 characters"}
      value -> {:ok, value}
    end
  end

  def cast(%{type: :text}, value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) > 500,
      do: {:error, "must be at most 500 characters"},
      else: {:ok, value}
  end

  def cast(%{type: :email}, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, ""}

      value ->
        if value =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
          do: {:ok, value},
          else: {:error, "must be a valid email"}
    end
  end

  def cast(_definition, _value), do: {:error, "is invalid"}
end
