defmodule FireflyPlugins.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The domain runs uploaded plugins through whichever sandbox registered;
    # it never references this app.
    Firefly.Plugins.Registry.register_sandbox(FireflyPlugins.Sandboxed)

    Supervisor.start_link([], strategy: :one_for_one, name: FireflyPlugins.Supervisor)
  end
end
