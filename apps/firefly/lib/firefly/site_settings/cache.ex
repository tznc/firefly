defmodule Firefly.SiteSettings.Cache do
  @moduledoc """
  Clears this node's cached site settings when another node changes them,
  and reloads custom emoji and watched words (both loaded here at start
  too) when another node changes them: `Firefly.SiteSettings`,
  `Firefly.Rendering.Emoji` and `Firefly.Moderation.WatchedWords` broadcast
  on the site settings PubSub topic.
  """
  use GenServer
  require Logger

  alias Firefly.SiteSettings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok = Phoenix.PubSub.subscribe(Firefly.PubSub, SiteSettings.topic())
    load_emoji()
    load_watched_words()
    {:ok, nil}
  end

  @impl true
  def handle_info(:site_settings_changed, state) do
    SiteSettings.clear_cache()
    {:noreply, state}
  end

  # This node's own changes are already loaded.
  def handle_info({:emoji_changed, from}, state) do
    if from != node(), do: load_emoji()
    {:noreply, state}
  end

  def handle_info({:watched_words_changed, from}, state) do
    if from != node(), do: Firefly.Moderation.WatchedWords.reload()
    {:noreply, state}
  end

  # Without the database (yet), the first render loads them instead.
  defp load_emoji do
    Firefly.Rendering.Emoji.reload()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Custom emoji not loaded: " <> Exception.message(error))
  end

  defp load_watched_words do
    Firefly.Moderation.WatchedWords.reload()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Watched words not loaded: " <> Exception.message(error))
  end
end
