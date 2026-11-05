defmodule Firefly.Jobs.Periodic do
  @moduledoc """
  The periodic work, each task an Oban worker (`Firefly.Jobs.Periodic.<Task>`)
  on a cron schedule (`crontab/0`, Oban's cron plugin). Only the leading node
  inserts cron jobs, so each run happens once across the cluster; a task
  isn't inserted again while its last run is still waiting or running, and a
  failed run isn't retried (the next one comes soon enough). Nothing runs
  while the site is read-only (see `Firefly.Backups`).

  | Task | When | Queue |
  | --- | --- | --- |
  | `TopicTimers`, `BookmarkReminders` | every minute, and at each timer's or reminder's own time (`Firefly.Jobs.run_at/2`) | default |
  | `PollClosing` | every minute | default |
  | `UnusedUploads`, `LinkPreviews` | every minute | maintenance |
  | `Embeddings` (semantic search) | every minute | ai |
  | `PluginJobs` (plugins' own scheduled jobs, see `Firefly.Plugins.Jobs`) | every minute | plugins |
  | `Badges` | every 15 minutes | maintenance |
  | `JailCleanup` (ended IP bans, see `Firefly.Security.Jail`) | every 10 minutes | maintenance |
  | `Digests` | every 15 minutes | mailers |
  | `TrustLevels`, `Analytics`, `EmbedFeed`, `ChatRetention`, `EmailLog`, `EgressLog`, `Directory`, `Backups`, `IPRetention`, `Sessions` | hourly | maintenance |
  | `VersionCheck` | daily | maintenance |
  """

  # {worker, cron expression, queue, the work}
  @tasks [
    {TopicTimers, "* * * * *", :default, {Firefly.Moderation.TopicTimers, :run_due}},
    {BookmarkReminders, "* * * * *", :default, {Firefly.Discussion.Bookmarks, :run_due}},
    {PollClosing, "* * * * *", :default, {Firefly.Discussion.Polls, :run_due}},
    {UnusedUploads, "* * * * *", :maintenance, {Firefly.Uploads, :run_due}},
    {LinkPreviews, "* * * * *", :maintenance, {Firefly.Rendering.LinkPreviews, :run_due}},
    {Embeddings, "* * * * *", :ai, {Firefly.AI, :run_due}},
    {PluginJobs, "* * * * *", :plugins, {Firefly.Plugins, :run_due_jobs}},
    {Badges, "*/15 * * * *", :maintenance, {Firefly.Badges, :run_due}},
    {Digests, "*/15 * * * *", :mailers, {Firefly.Notifications.Digests, :run_due}},
    # The hourly ones, spread over the hour.
    {TrustLevels, "5 * * * *", :maintenance, {Firefly.TrustLevels, :run_due}},
    {Analytics, "10 * * * *", :maintenance, {Firefly.Analytics, :run_due}},
    {EmbedFeed, "15 * * * *", :maintenance, {Firefly.Embedding, :run_due}},
    {ChatRetention, "20 * * * *", :maintenance, {Firefly.Chat, :run_due}},
    {EmailLog, "25 * * * *", :maintenance, {Firefly.Notifications.EmailLog, :run_due}},
    {EgressLog, "30 * * * *", :maintenance, {Firefly.Plugins.Egress, :run_due}},
    {Directory, "35 * * * *", :maintenance, {Firefly.Directory, :run_due}},
    {Backups, "45 * * * *", :maintenance, {Firefly.Backups, :run_due}},
    {IPRetention, "50 * * * *", :maintenance, {Firefly.Security, :run_retention}},
    {Sessions, "55 * * * *", :maintenance, {Firefly.Accounts.UserSessions, :run_cleanup}},
    {JailCleanup, "*/10 * * * *", :maintenance, {Firefly.Security.Jail, :run_cleanup}},
    {VersionCheck, "23 4 * * *", :maintenance, {Firefly.Upgrades, :run_due}}
  ]

  for {name, _cron, queue, {module, function}} <- @tasks do
    contents =
      quote do
        @moduledoc "Runs `#{inspect(unquote(module))}.#{unquote(function)}/0` (see `Firefly.Jobs.Periodic`)."

        # Not while the last run waits or runs (a slow backup isn't doubled);
        # a run scheduled for a timer's time doesn't count.
        use Oban.Worker,
          queue: unquote(queue),
          max_attempts: 1,
          unique: [period: :infinity, states: [:available, :executing]]

        @impl Oban.Worker
        def perform(_job),
          do:
            Firefly.Jobs.Periodic.run(unquote(module), fn ->
              unquote(module).unquote(function)()
            end)
      end

    Module.create(Module.concat(__MODULE__, name), contents, Macro.Env.location(__ENV__))
  end

  @doc "The cron schedule, for Oban's cron plugin: `[{expression, worker}]`."
  @spec crontab() :: [{String.t(), module}]
  def crontab, do: for({name, cron, _queue, _work} <- @tasks, do: {cron, worker(name)})

  @doc "The worker of the task `name` (`TopicTimers`...)."
  # Sobelow: names come from the fixed @tasks table.
  # sobelow_skip ["DOS.ModuleConcat"]
  def worker(name), do: Module.concat(__MODULE__, name)

  @doc false
  # Runs a task's work (a `[:firefly, :scheduler, :job]` span named after
  # `module`), unless the site is read-only.
  def run(module, work) do
    unless Firefly.Backups.read_only?() do
      Firefly.Telemetry.span([:firefly, :scheduler, :job], %{job: inspect(module)}, fn ->
        {work.(), %{}}
      end)
    end

    :ok
  end
end
