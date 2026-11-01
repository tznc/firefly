defmodule FirestormWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: FirestormWeb.Supervisor]

    Supervisor.start_link(
      children(Application.get_env(:firestorm_web, :notifications_enabled)),
      opts
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    FirestormWeb.Web.Endpoint.config_change(changed, removed)
    :ok
  end

  defp default_children do
    [
      # Start the Ecto repository
      FirestormWeb.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: FirestormWeb.PubSub},
      # Clears cached site settings when another node changes them
      FirestormWeb.SiteSettings.Cache,
      # Rate limit buckets
      {FirestormWeb.RateLimit, clean_period: :timer.minutes(10)},
      # Add an LRU Cache for storing OEmbed results for a given URL, storing at
      # most 5000 results at a time in the cache.
      %{id: LruCache, start: {LruCache, :start_link, [:oembed_cache, 5_000]}},
      # Start the endpoint when the application starts
      FirestormWeb.Web.Endpoint
    ] ++ topic_timers()
  end

  # Runs due thread timers (close, reopen or delete at a set time),
  # bookmark reminders and poll closings. Off in tests, which run them inside their own
  # database transaction.
  defp topic_timers do
    if Application.get_env(:firestorm_web, FirestormWeb.TopicTimers, [])[:enabled] == false,
      do: [],
      else: [FirestormWeb.TopicTimers.Scheduler]
  end

  defp children(false), do: default_children()

  defp children(_) do
    # Start the notifications server
    default_children() ++ [FirestormWeb.Notifications]
  end
end
