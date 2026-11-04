defmodule FireflyWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Spans and log export, when on (OpenTelemetry's SDK has started: it's a dependency).
    FireflyWeb.OpenTelemetry.setup()

    children = [
      # Who's in which chat channel (see FireflyWeb.ChatLive)
      FireflyWeb.Presence,
      # Metrics, when on: the reporter, the poller and their listener
      FireflyWeb.Telemetry,
      # Start the endpoint when the application starts
      FireflyWeb.Endpoint,
      # Fails readiness probes on shutdown, before the endpoint stops
      FireflyWeb.Draining
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FireflyWeb.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FireflyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
