defmodule Firefly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Firefly.Supervisor]

    Supervisor.start_link(
      children(Application.get_env(:firefly, :notifications_enabled)),
      opts
    )
  end

  defp default_children do
    [
      # Start the Ecto repository
      Firefly.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Firefly.PubSub},
      # Clears cached site settings when another node changes them
      Firefly.SiteSettings.Cache,
      # Rate limit buckets
      {Firefly.RateLimit, clean_period: :timer.minutes(10)},
      # Add an LRU Cache for storing OEmbed results for a given URL, storing at
      # most 5000 results at a time in the cache.
      %{id: LruCache, start: {LruCache, :start_link, [:oembed_cache, 5_000]}},
      # Runs plugin calls, so a crashing or runaway call never takes its caller down
      {Task.Supervisor, name: Firefly.Plugin.TaskSupervisor},
      # Loads plugins and reloads them when another node changes them
      Firefly.Plugins.Registry,
      # Fetches link previews in the background
      {Task.Supervisor, name: Firefly.Rendering.LinkPreviews.supervisor()},
      {Task.Supervisor, name: Firefly.Notifications.WebPush.TaskSupervisor},
      # Runs AI work in the background (triage, embeddings)
      {Task.Supervisor, name: Firefly.AI.TaskSupervisor},
      # Checks new content with Akismet in the background
      {Task.Supervisor, name: Firefly.Moderation.Akismet.TaskSupervisor},
      # Background and scheduled jobs (see Firefly.Jobs)
      {Oban, Application.fetch_env!(:firefly, Oban)},
      # Runs readiness probes' database checks, bounded by a timeout
      {Task.Supervisor, name: Firefly.Health.TaskSupervisor},
      # Posts as plugins transformed them
      Firefly.Plugins.Content.cache_spec(),
      # Counts traffic in memory and writes it in batches
      Firefly.Analytics.Buffer,
      # Reports' results for the day
      Firefly.Reports.Cache,
      # Runs backups and restores; applies read-only mode
      Firefly.Backups.Runner
    ] ++ topic_timers() ++ plugin_queue()
  end

  # Delivers plugin events and runs plugins' scheduled jobs. Off in tests,
  # which run them inside their own database transaction.
  defp plugin_queue do
    if Application.get_env(:firefly, Firefly.Plugins.Queue, [])[:enabled] == false,
      do: [],
      else: [Firefly.Plugins.Queue]
  end

  # Runs due thread timers (close, reopen or delete at a set time),
  # bookmark reminders and poll closings. Off in tests, which run them inside their own
  # database transaction.
  defp topic_timers do
    if Application.get_env(:firefly, Firefly.Moderation.TopicTimers, [])[:enabled] == false,
      do: [],
      else: [Firefly.Moderation.TopicTimers.Scheduler]
  end

  defp children(false), do: default_children()

  defp children(_) do
    # Start the notifications server
    default_children() ++ [Firefly.Notifications]
  end
end
