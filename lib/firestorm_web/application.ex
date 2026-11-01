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
      # Rate limit buckets
      {FirestormWeb.RateLimit, clean_period: :timer.minutes(10)},
      # Add an LRU Cache for storing OEmbed results for a given URL, storing at
      # most 5000 results at a time in the cache.
      %{id: LruCache, start: {LruCache, :start_link, [:oembed_cache, 5_000]}},
      # Start the endpoint when the application starts
      FirestormWeb.Web.Endpoint
    ]
  end

  defp children(false), do: default_children()

  defp children(_) do
    # Start the notifications server
    default_children() ++ [FirestormWeb.Notifications]
  end
end
