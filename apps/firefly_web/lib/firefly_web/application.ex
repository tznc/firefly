defmodule FireflyWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Who's in which chat channel (see FireflyWeb.ChatLive)
      FireflyWeb.Presence,
      # Start the endpoint when the application starts
      FireflyWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FireflyWeb.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FireflyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
