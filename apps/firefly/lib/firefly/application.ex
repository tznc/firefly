defmodule Firefly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Firefly.Supervisor]

    Supervisor.start_link(children(), opts)
  end

  defp children do
    # Start the Ecto repositories (the forum's and the host database's
    # `control` schema's) and the vault for the secrets stored in them, then
    # join the other nodes (when clustering is on) before anything relies on
    # PubSub reaching them
    [Firefly.Repo, Firefly.Control.Repo, Firefly.Vault] ++
      Firefly.Cluster.child_specs() ++
      [
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
        # Background and scheduled jobs (see Firefly.Jobs): notification
        # fan-out and emails, web pushes, link previews, Akismet, AI work...
        {Oban,
         Keyword.put(Application.fetch_env!(:firefly, Oban), :cron,
           crontab: Firefly.Jobs.crontab()
         )},
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
      ]
  end
end
