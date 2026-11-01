defmodule FirestormWeb.SiteSettings.Cache do
  @moduledoc """
  Clears this node's cached site settings when another node changes them
  (`FirestormWeb.SiteSettings` broadcasts on its PubSub topic).
  """
  use GenServer

  alias FirestormWeb.SiteSettings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ok = Phoenix.PubSub.subscribe(FirestormWeb.PubSub, SiteSettings.topic())
    {:ok, nil}
  end

  @impl true
  def handle_info(:site_settings_changed, state) do
    SiteSettings.clear_cache()
    {:noreply, state}
  end
end
