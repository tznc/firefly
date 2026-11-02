defmodule FirestormWeb.SiteSettings.Cache do
  @moduledoc """
  Clears this node's cached site settings when another node changes them,
  and reloads custom emoji (loaded here at start too) when another node
  changes those: `FirestormWeb.SiteSettings` and `FirestormWeb.Emoji`
  broadcast on the site settings PubSub topic.
  """
  use GenServer
  require Logger

  alias FirestormWeb.SiteSettings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok = Phoenix.PubSub.subscribe(FirestormWeb.PubSub, SiteSettings.topic())
    load_emoji()
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

  # Without the database (yet), the first render loads them instead.
  defp load_emoji do
    FirestormWeb.Emoji.reload()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Custom emoji not loaded: " <> Exception.message(error))
  end
end
